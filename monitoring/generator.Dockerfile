FROM python:3.12-alpine

WORKDIR /app

RUN pip install --no-cache-dir pyyaml

COPY generate-targets.py /app/generate-targets.py

ENTRYPOINT ["python", "/app/generate-targets.py"]