#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "❌ Скрипт нужно запускать от root"
  exit 1
fi

for dep in ip iptables curl; do
  if ! command -v "$dep" &>/dev/null; then
    echo "❌ Не найдено: $dep"
    exit 1
  fi
done

#Globals
WAN_IFACE=""
BASE_SUBNET=""
NS_LIST=()
RULES=()
VETH_LIST=()
ALIASES=()
IP_FORWARD_BEFORE=""

detect_wan_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' \
    || ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
    || ip -o link show up | awk -F': ' '{if ($2!="lo") {print $2; exit}}'
}

find_free_base_subnet() {
  for n in $(seq 200 250); do
    base="10.${n}"
    if ! ip route | grep -q "^10\.${n}\."; then
      echo "$base"; return
    fi
  done
  echo ""
}

remove_from_array() {
  local -n arr=$1
  local val=$2
  arr=($(printf "%s\n" "${arr[@]}" | grep -vx "$val"))
}

cleanup() {
  echo "🧹 Очистка..."
  for ns in "${NS_LIST[@]}"; do
    ip netns del "$ns" 2>/dev/null || true
  done
  for rule in "${RULES[@]}"; do
    iptables -t nat -D POSTROUTING $rule 2>/dev/null || true
  done
  for veth in "${VETH_LIST[@]}"; do
    ip link delete "$veth" 2>/dev/null || true
  done
  for alias_file in "${ALIASES[@]}"; do
    rm -f "$alias_file"
  done
  [ -n "$IP_FORWARD_BEFORE" ] && \
    sysctl -w net.ipv4.ip_forward="$IP_FORWARD_BEFORE" >/dev/null
  echo "✅ Всё очищено"
}
trap cleanup INT TERM EXIT

create_namespace() {
  local id=$1
  local ns="vpn$id"
  local veth="veth$id"
  local veth_br="veth${id}-br"
  local subnet="${BASE_SUBNET}.${id}.0/24"
  local host_ip="${BASE_SUBNET}.${id}.1"
  local ns_ip="${BASE_SUBNET}.${id}.2"

  if [[ " ${NS_LIST[*]} " == *" $ns "* ]]; then
    echo "⚠️ Namespace $ns уже существует"
    return
  fi

  echo "➕ Создаю $ns"

  ip netns add "$ns"

  ip link add "$veth_br" type veth peer name "$veth"
  ip link set "$veth" netns "$ns"

  ip addr add "$host_ip/24" dev "$veth_br"
  ip link set "$veth_br" up

  ip netns exec "$ns" ip addr add "$ns_ip/24" dev "$veth"
  ip netns exec "$ns" ip link set "$veth" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route add default via "$host_ip"

  iptables -t nat -A POSTROUTING -s "$subnet" -o "$WAN_IFACE" -j MASQUERADE
  RULES+=("-s $subnet -o $WAN_IFACE -j MASQUERADE")

  NS_LIST+=("$ns")
  VETH_LIST+=("$veth_br")

  # создаём системный alias
  local wrapper="/usr/local/bin/$ns"
  cat > "$wrapper" <<EOF
#!/bin/bash
ip netns exec $ns "\$@"
EOF
  chmod +x "$wrapper"
  ALIASES+=("$wrapper")

  echo "✅ Namespace $ns готов. Используй: $ns <команда>"
}

kill_namespace() {
  local id=$1
  local ns="vpn$id"
  local veth="veth${id}-br"

  echo "🗑 Удаляю $ns"
  ip netns del "$ns" 2>/dev/null || true
  ip link delete "$veth" 2>/dev/null || true

  for i in "${!RULES[@]}"; do
    if [[ "${RULES[$i]}" == *"$ns"* ]]; then
      iptables -t nat -D POSTROUTING ${RULES[$i]} 2>/dev/null || true
      unset 'RULES[i]'
    fi
  done

  remove_from_array NS_LIST "$ns"
  remove_from_array VETH_LIST "$veth"

  local wrapper="/usr/local/bin/$ns"
  rm -f "$wrapper"
  remove_from_array ALIASES "$wrapper"

  echo "✅ $ns удалён"
}

list_namespaces() {
  echo "🌐 Текущие VPN namespace:"
  for ns in "${NS_LIST[@]}"; do
    echo " - $ns"
  done
}

status_namespaces() {
  for ns in "${NS_LIST[@]}"; do
    echo -n "$ns → "
    "$ns" curl -s --max-time 5 ifconfig.me || echo "нет ответа"
  done
}

WAN_IFACE="${WAN_IFACE:-$(detect_wan_iface)}"
if [ -z "$WAN_IFACE" ]; then
  echo "❌ Не удалось определить внешний интерфейс"
  exit 1
fi

BASE_SUBNET="${BASE_SUBNET:-$(find_free_base_subnet)}"
if [ -z "$BASE_SUBNET" ]; then
  echo "❌ Нет свободной подсети (10.200.x.0/24)"
  exit 1
fi

IP_FORWARD_BEFORE=$(sysctl -n net.ipv4.ip_forward)
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "🌐 WAN-интерфейс: $WAN_IFACE"
echo "📡 Базовая подсеть: $BASE_SUBNET.0.0/16"
echo "⚡ IP Forward был $IP_FORWARD_BEFORE → теперь включен"

while true; do
  read -rp "Введите команду: " -a input
  cmd="${input[0]:-}"
  args=("${input[@]:1}")

  case "$cmd" in
    '' ) ;;
    [0-9]*) create_namespace "$cmd" ;;
    list)   list_namespaces ;;
    status) status_namespaces ;;
    kill)   kill_namespace "${args[0]}" ;;
    help)   echo "Доступные команды: <число>, list, status, kill <id>, help, exit" ;;
    exit|quit) break ;;
    *) echo "❓ Неизвестная команда: $cmd" ;;
  esac
done
