FROM python:3.12-alpine
RUN pip install --no-cache-dir webauthn==2.7.1 && adduser -D -u 1000 parent
WORKDIR /app
COPY app.py /app/app.py
COPY static /app/static
USER 1000:10
CMD ["python", "-u", "/app/app.py"]
