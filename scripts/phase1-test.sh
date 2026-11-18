#!/bin/sh
# Phase 1 checks: enrollment, mTLS to the broker, per-device ACL, rejection cases.
set -u
cd "$(dirname "$0")/.."
pass=0; fail=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
ng()  { echo "FAIL: $1"; fail=$((fail+1)); }

# mosquitto clients run in the broker image, on the compose network, using the pki volume
mq() { docker compose run --rm --no-deps -T --entrypoint "$1" broker "$@"; }
MQ_TLS="-h broker.wolfota.test -p 8883 --cafile /pki/ca.crt"

echo "== scale to 3 devices"
docker compose up -d --scale device=3 >/dev/null 2>&1
sleep 8
n=$(docker compose logs --no-color device | grep -c "MQTT connected as")
[ "$n" -ge 3 ] && ok "3 devices enrolled and connected ($n)" || ng "devices connected: $n"

dev=$(docker compose logs --no-color device | sed -n 's/.*MQTT connected as \([0-9a-f]*\).*/\1/p' | head -1)
echo "   device under test: $dev"

echo "== deploy service (cert CN=deploy) sees retained online status"
st=$(docker compose run --rm --no-deps -T --entrypoint mosquitto_sub broker $MQ_TLS \
     --cert /pki/deploy.crt --key /pki/deploy.key -t "wolfota/$dev/status" -C 1 -W 5 2>/dev/null)
echo "$st" | grep -q online && ok "status of $dev = $st" || ng "status of $dev: '$st'"

echo "== deploy service can publish to the device"
docker compose run --rm --no-deps -T --entrypoint mosquitto_pub broker $MQ_TLS \
     --cert /pki/deploy.crt --key /pki/deploy.key -t "wolfota/$dev/control" -m '{"cmd":"ping"}' -q 1
sleep 1
docker compose logs --no-color device | grep -q "message on wolfota/$dev/control" \
    && ok "device received control message" || ng "device did not receive control message"

echo "== connection without client certificate is rejected"
docker compose run --rm --no-deps -T --entrypoint mosquitto_pub broker $MQ_TLS \
     -t "wolfota/$dev/status" -m x >/dev/null 2>&1 \
    && ng "anonymous TLS client accepted" || ok "anonymous TLS client rejected"

echo "== device certificate cannot reach another device's topics (ACL)"
cid=$(docker compose ps -q device | head -1)
d1=$(docker exec "$cid" hostname)
others=$(docker compose logs --no-color device | sed -n 's/.*MQTT connected as \([0-9a-f]*\).*/\1/p' | grep -v "$d1" | sort -u | wc -l)
net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$cid")
# copy the device identity into a throw-away mosquitto client container
tmp=$(docker create --network "$net" -v wolfota_pki:/pki:ro --entrypoint sh eclipse-mosquitto:2 -c "
  mosquitto_sub $MQ_TLS --cert /d.crt --key /d.key -t 'wolfota/#' -C 10 -W 3 -v >/tmp/all 2>/tmp/err
  mosquitto_sub $MQ_TLS --cert /d.crt --key /d.key -t 'wolfota/$d1/status' -C 1 -W 3 >/tmp/own 2>>/tmp/err
  echo own=\$(cat /tmp/own) all_foreign=\$(grep -v 'wolfota/$d1/' /tmp/all | grep -c wolfota) all_own=\$(grep -c 'wolfota/$d1/' /tmp/all) err=\$(cat /tmp/err)")
docker exec "$cid" cat /data/device.crt > "$TMPD/d.crt"
docker exec "$cid" cat /data/device.key > "$TMPD/d.key"
docker cp "$TMPD/d.crt" "$tmp:/d.crt" && docker cp "$TMPD/d.key" "$tmp:/d.key"
res=$(docker start -a "$tmp"); docker rm "$tmp" >/dev/null
echo "   $res (other connected devices: $others)"
echo "$res" | grep -q "own=.*online" && ok "device $d1 reads its own status" || ng "device $d1 cannot read own status"
echo "$res" | grep -q "all_foreign=0 all_own=[1-9]" && ok "wolfota/# delivers only $d1's own topics" || ng "ACL leak or no data"

echo "== EST rejects wrong bootstrap credential"
out=$(docker compose run --rm --no-deps -T --entrypoint sh device -c \
  'cd /tmp && wolfcert-client enroll --proto est --url https://est.wolfota.test:8443/.well-known/est \
   --trust /opt/o4d/trust/ca.crt --key-type ecc:256 --subject "CN=intruder" \
   --user wolfota --pass wrong --out-key k --out-cert c 2>&1')
echo "   $out" | head -2
echo "$out" | grep -q -i "401\|auth" && ok "wrong credential rejected" || ng "wrong credential not rejected"

echo
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
