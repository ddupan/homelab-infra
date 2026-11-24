FROM postgres:19-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv pgbackrest openssh-client haproxy && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/patroni && /opt/patroni/bin/pip install --no-cache-dir 'patroni[etcd3,psycopg3]==4.1.5'
ENTRYPOINT []
