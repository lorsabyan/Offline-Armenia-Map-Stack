# Pinned: python:3.13-alpine
FROM python:3.13-alpine@sha256:bb1f2fdb1065c85468775c9d680dcd344f6442a2d1181ef7916b60a623f11d40

RUN apk add --no-cache curl su-exec

ENV PYTHONUNBUFFERED=1

COPY manager.py /app/manager.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
WORKDIR /app

RUN addgroup -g 1000 manager && adduser -D -u 1000 -G manager manager \
    && chown -R manager:manager /app

EXPOSE 8000

# Start as root to fix volume permissions, then drop to manager user
ENTRYPOINT ["/app/entrypoint.sh"]
