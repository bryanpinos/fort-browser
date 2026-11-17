"""Does Gemma's yes/no 'needs the web?' match what a parent would expect? Prints accuracy and latency."""
import json, os, math, sys, time, urllib.request as u
URL = os.environ.get("LMSTUDIO_URL", "http://localhost:1234") + "/v1/chat/completions"
SEARCH = [
    "Who won the World Series this year?", "What's the weather going to be tomorrow in Boston?",
    "When is the next Minecraft update coming out?", "What are the newest Pokemon?",
    "Who is the president of the United States right now?", "What movies are in theaters right now?",
    "How much does a Nintendo Switch 2 cost?", "What did the James Webb telescope discover recently?",
    "Is the new Lego Star Wars set out yet?", "What's the score of the Patriots game?",
    "What's the tallest building in the world right now?", "Did anything cool happen in space this week?",
    "What time does the Boston Museum of Science open on Saturday?", "Who is the best player in the NBA this season?",
]
NO_SEARCH = [
    "Tell me a story about a dragon who is afraid of marshmallows.", "What's 7 times 8?", "How do you spell necessary?",
    "Why is the sky blue?", "Can you quiz me on multiplication?", "Write a poem about my cat.", "What rhymes with orange?",
    "How do I say thank you in Spanish?", "Tell me a joke.", "What's the difference between a frog and a toad?",
    "Help me write a thank-you note to my grandma.", "What should I name my hamster?", "I'm bored. What can I do?",
    "Can you explain fractions?", "How do plants make their own food?", "What year did the Titanic sink?",
]
PROMPT = sys.argv[1] if len(sys.argv) > 1 else (
    "You decide whether a children's chat helper should search the web before answering. Answer yes only if a good "
    "answer needs current or very specific facts you may not know: recent news, sports scores, schedules, weather, "
    "prices, new releases, or things that change over time. Answer no for stories, jokes, games, homework help, math, "
    "spelling, writing help, and explanations of things that don't change. Answer only yes or no.")
def ask(q):
    """1.0 for yes, 0.0 for no. Gemma (MLX) returns no logprobs, so read the answer text."""
    body = {"model": "gemma-4-31b-it", "temperature": 0, "max_tokens": 5,
            "messages": [{"role": "system", "content": PROMPT}, {"role": "user", "content": q}]}
    t0 = time.time()
    try:
        c = json.load(u.urlopen(u.Request(URL, json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=60))["choices"][0]
    except u.HTTPError as e:
        raise SystemExit(f"HTTP {e.code} for {q!r}: {e.read().decode()[:300]}")
    text = (c["message"].get("content") or "").strip().lower()
    return (1.0 if text.startswith("yes") else 0.0 if text.startswith("no") else 0.5), time.time() - t0
times, wrong = [], []
for want, qs in ((True, SEARCH), (False, NO_SEARCH)):
    for q in qs:
        s, dt = ask(q); times.append(dt)
        if (s > 0.5) != want: wrong.append(f"{'SHOULD' if want else 'should NOT'} search ({s:.2f}): {q}")
total = len(SEARCH) + len(NO_SEARCH)
print(f"{total - len(wrong)}/{total} right; avg {sum(times)/len(times):.2f}s, max {max(times):.2f}s")
for w in wrong: print("  ", w)
