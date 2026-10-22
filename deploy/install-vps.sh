#!/bin/sh
set -eu
upload=$1
stamp=$(date -u +%Y%m%dT%H%M%SZ)
base=/opt/cc-assistant
node_archive=node-v22.22.3-linux-x64.tar.xz
expected=$(awk -v file="$node_archive" '$2 == file {print $1}' "$upload/SHASUMS256.txt")
actual=$(sha256sum "$upload/$node_archive" | cut -d ' ' -f 1)
[ "$actual" = "$expected" ] || { echo 'Runtime checksum mismatch'; exit 1; }
id cc-assistant >/dev/null 2>&1 || useradd --system --home /var/lib/cc-assistant --shell /usr/sbin/nologin cc-assistant
install -d -m 0755 "$base/releases/$stamp" "$base/runtime"
install -d -m 0700 -o cc-assistant -g cc-assistant /var/lib/cc-assistant
tar -xJf "$upload/$node_archive" -C "$base/runtime" --strip-components=1
install -m 0644 "$upload/server.mjs" "$base/releases/$stamp/server.mjs"
ln -sfn "$base/releases/$stamp" "$base/current"
install -m 0644 "$upload/cc-assistant-subscriptions.service" /etc/systemd/system/cc-assistant-subscriptions.service
install -m 0644 "$upload/nginx-subscriptions.conf" /etc/nginx/snippets/cc-assistant-subscriptions.conf
config=/etc/nginx/sites-available/node.tangchen02.top
cp -a "$config" "$config.before-cc-$stamp"
python3 - "$config" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text();needle='server_name node.tangchen02.top;';include='include /etc/nginx/snippets/cc-assistant-subscriptions.conf;'
if include not in s:
 if s.count(needle)!=1:raise SystemExit('Unexpected existing server block; refusing to change nginx')
 p.write_text(s.replace(needle,needle+'\n '+include,1))
PY
if ! nginx -t; then cp -a "$config.before-cc-$stamp" "$config"; exit 1; fi
systemctl daemon-reload
systemctl enable cc-assistant-subscriptions.service
systemctl restart cc-assistant-subscriptions.service
healthy=0
for attempt in 1 2 3 4 5; do
    if curl --fail --silent --max-time 5 http://127.0.0.1:19480/api/health >/dev/null; then healthy=1; break; fi
    sleep 1
done
[ "$healthy" = 1 ] || { echo "Subscription health check failed; nginx was not reloaded"; exit 1; }
systemctl reload nginx
printf 'Subscription service installed; nginx and Xray preserved.\n'
