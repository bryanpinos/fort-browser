FROM python:3.12-alpine
WORKDIR /app
COPY collector.py .
VOLUME /data
EXPOSE 8089
CMD ["python", "collector.py"]
