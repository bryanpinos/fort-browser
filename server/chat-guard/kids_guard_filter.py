"""
title: Kids Guard
author: Fort
description: Checks every message and reply in the kids' chat with two local guard models. Fails closed.
version: 0.1.0
requirements: aiohttp
"""
# Attach to the kids' model only. How it holds up:
#  - Stream and outlet exceptions are swallowed by Open WebUI (they fail open), so
#    those hooks catch everything themselves and withhold text on any error.
#  - Text is held back and released in checked batches, so unchecked words never
#    reach the browser or the saved chat.
#  - Kids can set a system prompt and features in the chat UI, so inlet overwrites them.
# Thresholds came from server/chat-guard/eval; re-run it before changing them.
import hashlib
import json
import logging
import math
import time
from collections import OrderedDict

import aiohttp
from pydantic import BaseModel, Field

log = logging.getLogger("kids_guard")

SHIELD_SYSTEM = ('Judge whether the Document meets the requirements based on the Query '
                 'and the Instruction provided. Note that the answer can only be "yes" or "no".')
INSTRUCT = ("You are a careful safety moderator for a chatbot used by children aged 9 to 13. Ordinary "
            "curiosity about school subjects, history, science, health and growing up is fine, and so is "
            "a reply that kindly refuses or sends the child to a trusted adult.")
Q_BLOCK = ("Does this ask for or provide something a chatbot should not give a child aged 9 to 13, such as sexual "
           "content, instructions for violence, weapons, drugs, alcohol, crime, gambling, cruelty, hate, getting "
           "around parental controls, or keeping secrets from parents?")
Q_ALERT = ("Does this suggest a child may be in danger and needs a trusted adult, such as thoughts of suicide or "
           "self-harm, disordered eating, abuse, a threat of violence, running away, or an adult or stranger "
           "asking for secrecy, pictures, an address, or to meet?")

SYSTEM_PROMPT = ("You are a friendly helper for kids aged 9 to 13. Use simple, kind, encouraging words and keep "
                 "answers fairly short. Help with school, hobbies, games, stories and curiosity. Don't discuss "
                 "sexual content, how to hurt anyone, drugs, alcohol, or breaking rules, and don't ask for personal "
                 "information. Never ask a child to keep a secret from a parent. For big worries, encourage talking "
                 "to a parent or another trusted adult.")
DECLINE_INSTRUCTION = ("A child asked for something that isn't right for this chat. Reply with exactly this, "
                       "and nothing else: That's not something I can help with. Want to ask me about something else?")
# Worded for not knowing what happened: blocked messages never reach the model, and
# the person who should be told may be the person causing the harm.
CARE_INSTRUCTION = ("A child may be going through something hard or may not be safe. Reply with exactly this, and nothing "
                    "else: I'm really glad you told me, and none of this is your fault. Please tell a grown-up you trust "
                    "right now, like a parent, a teacher, a school counselor, or another relative. If the problem is with "
                    "someone at home, pick someone else you trust. If you ever feel like hurting yourself, you can call or "
                    "text 988 any time. If you're in danger right now, call 911.")
WITHHELD_REPLY = "Hmm, I can't share that one. Want to ask me something else, or check with a grown-up?"
GUARD_DOWN = "The chat's safety check isn't working right now, so I can't answer. Please try again in a little while."

# Qwen3Guard's official response-moderation prompt. LM Studio treats a final
# assistant message as text to continue, so reply checks use a raw completion.
QWEN_REPLY_TEMPLATE = "<|im_start|>user\n# Task:\n1) Evaluate whether THE LAST ASSISTANT's response belongs to safe or unsafe content based on our safety policy.\n2) Identify the category of unsafe content found.\n3) Determine if THE LAST ASSISTANT's response is a refusal to the USER's query.\n\n<BEGIN SAFETY POLICY>\n**Safety: Safe**: The ASSISTANT's response does not contain any prohibited content or content that could lead to prohibited content.\n**Safety: Unsafe**: The ASSISTANT's response contains prohibited content.\n**Safety: Controversial**: The ASSISTANT's response is not explicitly harmful, but could become risky or offensive depending on context or audience.\n<END SAFETY POLICY>\n\n<BEGIN UNSAFE CONTENT CATEGORIES>\nViolent.\nNon-violent Illegal Acts.\nSexual Content or Sexual Acts.\nPII.\nSuicide & Self-Harm.\nUnethical Acts.\nPolitically Sensitive Topics.\nCopyright Violation.\n<END UNSAFE CONTENT CATEGORIES>\n\n<BEGIN REFUSAL POLICY>\n**Refusal: Yes**: The ASSISTANT refused to answer or did not comply with the USER's request.\n**Refusal: No**: The ASSISTANT directly answered or complied with the USER's request.\n<END REFUSAL POLICY>\n\n<BEGIN CONVERSATION>\n\nUSER: @@KID@@\n\nASSISTANT: @@REPLY@@\n\n<END CONVERSATION>\n\nProvide your safety assessment for ONLY THE LAST **ASSISTANT's response** in the above conversation:\n - The first line must be one of: 'Safety: Safe', 'Safety: Unsafe', 'Safety: Controversial'.\n - The second line should start with 'Categories:' followed by a list of any unsafe content categories, separated by commas. If the content is safe, use 'Categories: None'.\n - The third line must be one of: 'Refusal: Yes', 'Refusal: No'.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"


class GuardError(Exception):
    pass


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=-100, description="Run before other filters.")
        lm_url: str = Field(default="http://host.docker.internal:1234/v1", description="LM Studio base URL")
        qwen_model: str = Field(default="qwen3guard-gen-4b")
        shield_model: str = Field(default="shieldstral-1.0-3b")
        block_threshold: float = Field(default=0.5)
        alert_threshold: float = Field(default=0.15)
        max_message_chars: int = Field(default=4000, description="Longer messages are refused, not truncated.")
        batch_chars: int = Field(default=200, description="Release reply text after checking this much.")
        alert_webhook_url: str = Field(default="", description="Home Assistant webhook. A secret: keep it here, not in code.")

    def __init__(self):
        self.valves = self.Valves()
        self._verdicts = OrderedDict()
        self._streams = {}
        self._alerted = {}

    # ---- guard calls -----------------------------------------------------

    async def _post(self, path, body):
        try:
            timeout = aiohttp.ClientTimeout(total=60)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(f"{self.valves.lm_url}/{path}", json=body) as r:
                    if r.status != 200:
                        raise GuardError(f"{path}: HTTP {r.status}")
                    return await r.json()
        except GuardError:
            raise
        except Exception as e:
            raise GuardError(f"{path}: {e!r}") from e

    @staticmethod
    def _parse_qwen(text):
        for label in ("Unsafe", "Controversial", "Safe"):
            if f"Safety: {label}" in text:
                return label
        raise GuardError(f"unreadable Qwen3Guard answer: {text[:80]!r}")

    async def _qwen_prompt(self, text):
        out = await self._post("chat/completions", {
            "model": self.valves.qwen_model, "temperature": 0, "max_tokens": 40,
            "messages": [{"role": "user", "content": text}]})
        return self._parse_qwen(out["choices"][0]["message"]["content"])

    async def _qwen_reply(self, kid, reply):
        prompt = QWEN_REPLY_TEMPLATE.replace("@@KID@@", kid).replace("@@REPLY@@", reply)
        out = await self._post("completions", {
            "model": self.valves.qwen_model, "temperature": 0, "max_tokens": 40,
            "prompt": prompt, "stop": ["<|im_end|>"]})
        return self._parse_qwen(out["choices"][0]["text"])

    async def _shield(self, query, kid, reply=None):
        doc = f"[User]\n{kid}" + (f"\n\n[Assistant]\n{reply}" if reply is not None else "")
        out = await self._post("chat/completions", {
            "model": self.valves.shield_model, "temperature": 0, "max_tokens": 1, "logprobs": True, "top_logprobs": 20,
            "messages": [{"role": "system", "content": SHIELD_SYSTEM},
                         {"role": "user", "content": f"<Instruct>: {INSTRUCT}\n\n<Query>: {query}\n\n<Document>: {doc}"}]})
        choice = out["choices"][0]
        try:
            yes, no = -10.0, -10.0
            for t in choice["logprobs"]["content"][0]["top_logprobs"]:
                word = t["token"].strip().lower()
                if word.startswith("yes"):
                    yes = max(yes, t["logprob"])
                elif word.startswith("no"):
                    no = max(no, t["logprob"])
            return math.exp(yes) / (math.exp(yes) + math.exp(no))
        except (KeyError, IndexError, TypeError):
            answer = (choice["message"]["content"] or "").strip().lower()
            if answer.startswith("yes"):
                return 1.0
            if answer.startswith("no"):
                return 0.0
            raise GuardError(f"unreadable Shieldstral answer: {answer[:80]!r}")

    async def _check_message(self, text):
        """Verdict for one kid message, cached because history is re-sent every turn."""
        key = hashlib.sha256(text.encode()).hexdigest()
        if key in self._verdicts:
            self._verdicts.move_to_end(key)
            return self._verdicts[key]
        if len(text) > self.valves.max_message_chars:
            verdict = {"block": True, "alert": False}
        else:
            label = await self._qwen_prompt(text)
            block_score = await self._shield(Q_BLOCK, text)
            alert_score = await self._shield(Q_ALERT, text)
            verdict = {"block": label != "Safe" or block_score > self.valves.block_threshold,
                       "alert": alert_score > self.valves.alert_threshold}
        self._verdicts[key] = verdict
        while len(self._verdicts) > 2000:
            self._verdicts.popitem(last=False)
        return verdict

    async def _reply_is_safe(self, kid, reply):
        kid, reply = kid[-2000:], reply[-3000:]
        if await self._qwen_reply(kid, reply) != "Safe":
            return False
        return await self._shield(Q_BLOCK, kid, reply) <= self.valves.block_threshold

    # ---- alerting --------------------------------------------------------

    async def _alert(self, user, text):
        name = (user or {}).get("name") or "A kid"
        log.warning("kids guard alert for %s", name)
        if not self.valves.alert_webhook_url:
            return
        key = (name, hashlib.sha256(text.encode()).hexdigest())
        if time.time() - self._alerted.get(key, 0) < 600:
            return
        self._alerted[key] = time.time()
        try:
            timeout = aiohttp.ClientTimeout(total=10)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                await session.post(self.valves.alert_webhook_url, json={"kid": name, "message": text[:300]})
        except Exception as e:
            log.error("kids guard couldn't send an alert: %r", e)

    # ---- hooks -----------------------------------------------------------

    @staticmethod
    def _text_of(content):
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
        return ""

    async def inlet(self, body, __user__=None, __metadata__=None):
        if (__metadata__ or {}).get("task"):
            return body  # title and tag generation; the replies they summarize were already checked
        # Only this filter decides these, whatever the chat UI sent.
        for field in ("tools", "tool_ids", "files", "features", "tool_servers", "skill_ids"):
            body.pop(field, None)
        body["stream"] = True
        messages = [m for m in body.get("messages", []) if m.get("role") in ("user", "assistant")]
        users = [m for m in messages if m.get("role") == "user"]
        if not users:
            raise Exception(GUARD_DOWN)
        cleaned, latest, quiet = [], None, []
        try:
            for m in messages:
                text = self._text_of(m.get("content"))  # drops images and other parts
                if m.get("role") == "user":
                    latest = await self._check_message(text)
                    if latest["block"]:
                        text = "(message removed)"
                    elif not latest["alert"]:
                        quiet.append(text)
                cleaned.append({"role": m["role"], "content": text})
            # A worry can build across messages, even if none alarms on its own.
            # Only unflagged messages count, so one flagged message can't colour
            # every later turn. Stricter threshold: this path has no test data yet.
            recent = "\n".join(quiet[-3:])
            alert = latest["alert"]
            if not alert and not latest["block"] and len(quiet) > 1 and len(recent) <= self.valves.max_message_chars:
                alert = await self._shield(Q_ALERT, recent) > self.valves.block_threshold
        except GuardError as e:
            log.error("kids guard failed closed on a message: %s", e)
            raise Exception(GUARD_DOWN)
        kid_text = self._text_of(users[-1].get("content"))
        if alert:
            await self._alert(__user__, kid_text)
        system = SYSTEM_PROMPT
        if latest["block"]:
            cleaned = [{"role": "user", "content": "(message removed)"}]
            system = CARE_INSTRUCTION if alert else DECLINE_INSTRUCTION
        elif alert:
            system = CARE_INSTRUCTION
        body["messages"] = [{"role": "system", "content": system}] + cleaned
        return body

    async def stream(self, event, __body__=None):
        """Holds reply text back and releases it only after both guards pass it."""
        try:
            choices = event.get("choices")
            if not choices:
                return event
            key = event.get("id") or (__body__ or {}).get("id") or "stream"
            state = self._streams.setdefault(key, {"pending": "", "sent": "", "stopped": False})
            choice = choices[0]
            delta = choice.get("delta") or {}
            for hidden in ("reasoning_content", "reasoning", "thinking", "tool_calls", "function_call"):
                delta.pop(hidden, None)
            state["pending"] += delta.pop("content", None) or ""
            finished = choice.get("finish_reason") is not None
            release = ""
            if state["stopped"]:
                state["pending"] = ""
            elif state["pending"] and (finished or len(state["pending"]) >= self.valves.batch_chars):
                kid = ""
                for m in reversed((__body__ or {}).get("messages", [])):
                    if m.get("role") == "user":
                        kid = self._text_of(m.get("content"))
                        break
                if await self._reply_is_safe(kid, state["sent"] + state["pending"]):
                    release, state["pending"] = state["pending"], ""
                    state["sent"] += release
                else:
                    release, state["pending"], state["stopped"] = WITHHELD_REPLY, "", True
            if release:
                delta["content"] = release
            choice["delta"] = delta
            if finished:
                self._streams.pop(key, None)
            return event
        except Exception as e:
            log.error("kids guard withheld a reply: %r", e)
            try:
                key = event.get("id") or "stream"
                state = self._streams.setdefault(key, {"pending": "", "sent": "", "stopped": True})
                first = not state["stopped"]
                state.update(pending="", stopped=True)
                choice = (event.get("choices") or [{}])[0]
                delta = {"content": GUARD_DOWN} if first else {}
                choice["delta"] = delta
                if choice.get("finish_reason") is not None:
                    self._streams.pop(key, None)
                return event
            except Exception:
                return {}
