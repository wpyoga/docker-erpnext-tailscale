#!/bin/sh

usage() {
  cat <<EOF
usage: $0 <version> [--down|--restart] <project> <tailnet>

  version     currently only 13, 14, or 15
  --down      stop and remove containers (default is start and run)
  --restart   restart containers
  project     project name
  tailnet     tailnet name

EOF
}

if [ -z "$1" ]; then
  usage
  exit 1
fi

VER="$1"
shift
case "$VER" in
  13)
    YML_URL=https://github.com/frappe/frappe_docker/raw/67026915dd9130df952ed1aef3f169b0de83a636/pwd.yml
    NO_RESTART=''
    NO_NETWORK_NAME='#'
    ;;
  14)
    YML_URL=https://github.com/frappe/frappe_docker/raw/be174a164a283d2ae8dd971fca0db10db5652cc6/pwd.yml
    NO_RESTART='#'
    NO_NETWORK_NAME='#'
    ;;
  15)
    # v15.96.1 -- last v15 version
    YML_URL=https://github.com/frappe/frappe_docker/raw/3d46cb84e08bf37273beb877a254b97131e6abf5/pwd.yml
    # v15.94.3
    #YML_URL=https://github.com/frappe/frappe_docker/raw/bc254c2b4ceb9d01dbdd598ace2053326120d27f/pwd.yml
    # v15.94.2
    #YML_URL=https://github.com/frappe/frappe_docker/raw/56c6520e2905b2bdaf981db9293b20a4408e520d/pwd.yml
    # v15.92.5
    #YML_URL=https://github.com/frappe/frappe_docker/raw/43863d2537ed05549cceeab166ec695dd578b37b/pwd.yml
    # v15.85.1
    #YML_URL=https://github.com/frappe/frappe_docker/raw/78d21c2f4e79ac3974f4f4484290b8da4ba1adc0/pwd.yml
    NO_RESTART='#'
    NO_NETWORK_NAME=''
    ;;
   *)
    usage
    echo "Error: Invalid version specified"
    exit 1
    ;;
esac

# allow user to stop containers using this script
# we don't remove volumes when stopping containers though

CMD="up"
OPTS="-d"
if [ "$1" = "--down" ]; then
  CMD="down"
  OPTS=
  shift
elif [ "$1" = "--restart" ]; then
  CMD="restart"
  OPTS=
  shift
fi

[ -z "$1" ] && { echo "Project name cannot be empty."; exit 1; }
[ -z "$2" ] && { echo "Tailnet name cannot be empty."; exit 1; }

# a strict checking of domain name
# project name will be used as a subdomain, so it has to follow the rules, too

expr match "$1" '^[0-9A-Za-z]$' >/dev/null \
  || expr match "$1" '^[0-9A-Za-z][-0-9A-Za-z]*[0-9A-Za-z]$' >/dev/null \
  || { echo "Project name invalid: $1"; exit 1; }

expr match "$2" '^[0-9A-Za-z][-0-9A-Za-z]*[0-9A-Za-z]\.ts\.net$' >/dev/null \
  || { echo "Tailnet name invalid: $2"; exit 1; }

PROJECT="$1"
TAILNET="$2"

# base yaml file
wget -nc $YML_URL -O erpnext-$VER.yml

ERPNEXT_YML=`mktemp`
case "$VER" in
  13|14)
    sed -e 's,\(frappe/[0-9a-z][-0-9a-z]*[0-9a-z]:v'$VER'\)\.[0-9.]*,\1,' erpnext-$VER.yml > $ERPNEXT_YML
    ;;
  15)
    # should we automatically update to the latest v15 image?
    # we can achieve that by overriding the image tags to v15 or version-15
    # https://hub.docker.com/r/frappe/erpnext/tags
    cat erpnext-$VER.yml > $ERPNEXT_YML
    ;;
esac

TEMPFILE=`mktemp`
cat > $TEMPFILE <<EOF
configs:
  ts-serve:
    content: |
      {"TCP":{"443":{"HTTPS":true}},"Web":{"\$\${TS_CERT_DOMAIN}:443":{"Handlers":{"/":{"Proxy":"http://frontend:8080"}}}}}

services:
$NO_RESTART  create-site:
$NO_RESTART    deploy:
$NO_RESTART      restart_policy: !override
$NO_RESTART        condition: none
  scheduler:
    depends_on:
      - redis-queue
  queue-long:
    depends_on:
      - redis-queue
    deploy:
      restart_policy:
        condition: unless-stopped
  queue-short:
    depends_on:
      - redis-queue
    deploy:
      restart_policy:
        condition: unless-stopped
  websocket:
    depends_on:
      - redis-queue
  backend:
    depends_on:
      - db
    deploy:
      restart_policy:
        condition: unless-stopped

  frontend:
    ports: !reset
    depends_on:
      - backend
      - websocket

  redis-queue:
    deploy:
      restart_policy:
        condition: unless-stopped
  redis-cache:
    deploy:
      restart_policy:
        condition: unless-stopped

  db:
    deploy:
      restart_policy:
        condition: unless-stopped


  tailscale:
    image: tailscale/tailscale:latest
    hostname: $PROJECT
$NO_NETWORK_NAME    networks:
$NO_NETWORK_NAME      - frappe_network
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_SERVE_CONFIG=/config/serve.json
    configs:
      - source: ts-serve
        target: /config/serve.json
    volumes:
      - tailscale-data:/var/lib/tailscale
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - net_admin
      - sys_module
    restart: unless-stopped
    depends_on:
      - frontend
volumes:
  tailscale-data:
EOF

PODMAN_YML=`mktemp`
cat >$PODMAN_YML <<EOF
x-podman:
  name_separator_compat: true
EOF

DOCKER=`which docker` \
  || DOCKER=`which podman` \
  || { echo "docker and podman not found"; exit 1; }

$DOCKER compose -p $PROJECT -f $ERPNEXT_YML -f $TEMPFILE -f $PODMAN_YML $CMD $OPTS
rm $ERPNEXT_YML
rm $TEMPFILE

if [ "$CMD" = "up" ]; then
  echo "The first time $PROJECT-tailscale-1 runs, check the logs for the login link."
  echo "$DOCKER logs -f $PROJECT-tailscale-1"
fi

if [ "$CMD" = "down" ]; then
  echo "Check dangling volumes and prune any unused ones."
  echo "$DOCKER volume ls"
fi

