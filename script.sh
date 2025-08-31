#!/bin/bash
# Multi-VPN manager via Linux network namespaces

# Safety & deps
if [ "$EUID" -ne 0 ]; then
  echo "[!] Запусти скрипт с правами root (sudo)."
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] Требуется команда '$1'. Установи и повтори." ; exit 1 ; }
}
need_cmd ip
need_cmd iptables

# curl нужен только для 'status' (можите проверить :3)
if ! command -v curl >/dev/null 2>&1; then
  CURL_MISSING=1
else
  CURL_MISSING=0
fi

detect_wan_iface() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
  [ -z "$dev" ] && dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
  [ -z "$dev" ] && dev=$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
  echo "$dev"
}

WAN_IFACE="${WAN_IFACE:-$(detect_wan_iface)}"
if [ -z "$WAN_IFACE" ] || ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
  echo "[!] Не удалось определить WAN-интерфейс. Укажи переменной окружения:"
  echo "    sudo WAN_IFACE=wlan0 ./multi-vpn-manager.sh"
  exit 1
fi


# Автоподбор BASE_SUBNET (10.200–10.250)
find_free_base_subnet() {
  local base
  for n in $(seq 200 250); do
    base="10.${n}"

    if ! ip route | grep -q "^10\.${n}\."; then
      echo "$base"
      return
    fi
  done
  echo ""
}

BASE_SUBNET="${BASE_SUBNET:-$(find_free_base_subnet)}"
if [ -z "$BASE_SUBNET" ]; then
  echo "[!] Не удалось найти свободную подсеть в диапазоне 10.200–10.250."
  echo "    Укажи вручную: BASE_SUBNET=192.168 ./multi-vpn-manager.sh"
  exit 1
fi

# Globals
NS_LIST=()     # активные netns (имена: vpn<ID>)
RULES=()       # добавленные правила iptables
VETH_LIST=()   # список veth-бриджевых интерфейсов в хосте
ALIASES=()     # имена созданных alias-функций
PREV_IPF="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "")"


remove_from_array() {
  local name="$1" val="$2"
  eval "local arr=(\"\${$name[@]}\")"
  local out=()
  for e in "${arr[@]}"; do
    [[ "$e" == "$val" ]] || out+=("$e")
  done
  eval "$name=(\"\${out[@]}\")"
}


cleanup() {
  echo "[*] Чистим всё, что создали..."
  for ns in "${NS_LIST[@]}"; do
    ip netns delete "$ns" 2>/dev/null
  done
  for rule in "${RULES[@]}"; do
    iptables -t nat -D POSTROUTING $rule 2>/dev/null
  done
  for veth in "${VETH_LIST[@]}"; do
    ip link delete "$veth" 2>/dev/null
  done
  for alias_name in "${ALIASES[@]}"; do
    unset -f "$alias_name" 2>/dev/null
  done
  # Восстановление ip_forward
  if [ -n "$PREV_IPF" ] && [ "$PREV_IPF" = "0" ]; then
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1
  fi
  echo "[+] Готово. Всё удалено."
}
trap cleanup INT TERM EXIT


# Ensure ip_forward enabled
enable_ip_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || {
    echo "[!] Не удалось включить net.ipv4.ip_forward=1 — трафик из namespace может не ходить."
  }
}

# Create namespace
create_namespace() {
  local id="$1"
  local ns="vpn${id}"
  local veth="veth${id}"
  local veth_br="veth${id}-br"
  local subnet="${BASE_SUBNET}.${id}.0/24"
  local ip_ns="${BASE_SUBNET}.${id}.2"
  local ip_br="${BASE_SUBNET}.${id}.1"

  echo "[*] Создаём namespace $ns..."

  if ip netns list | grep -qw "$ns"; then
    echo "[!] $ns уже существует."
    return
  fi

  ip link delete "$veth_br" 2>/dev/null
  ip link delete "$veth" 2>/dev/null

  ip netns add "$ns"
  ip netns exec "$ns" ip link set lo up

  ip link add "$veth" type veth peer name "$veth_br"
  ip link set "$veth" netns "$ns"

  ip netns exec "$ns" ip link set "$veth" up
  ip netns exec "$ns" ip addr flush dev "$veth"
  ip netns exec "$ns" ip addr add "$ip_ns/24" dev "$veth"

  ip link set "$veth_br" up
  ip addr flush dev "$veth_br"
  ip addr add "$ip_br/24" dev "$veth_br"

  ip netns exec "$ns" ip route add default via "$ip_br"

  enable_ip_forward

  if ! iptables -t nat -C POSTROUTING -s "$subnet" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$WAN_IFACE" -j MASQUERADE
    RULES+=("-s $subnet -o $WAN_IFACE -j MASQUERADE")
  fi

  NS_LIST+=("$ns")
  VETH_LIST+=("$veth_br")

  local alias_name="$ns"
  if declare -F "$alias_name" >/dev/null 2>&1; then
    unset -f "$alias_name"
  fi
  eval "$alias_name() { ip netns exec $ns \"\$@\"; }"
  ALIASES+=("$alias_name")

  echo "[+] Готово: $ns (подсеть $subnet)"
  echo "    Примеры:  $ns curl ifconfig.me"
  echo "              $ns nmap -sT target"
  echo
}

# Delete specific namespace
kill_namespace() {
  local id="$1"
  local ns="vpn${id}"
  local veth_br="veth${id}-br"
  local subnet="${BASE_SUBNET}.${id}.0/24"
  local rule="-s $subnet -o $WAN_IFACE -j MASQUERADE"

  if ! ip netns list | grep -qw "$ns"; then
    echo "[!] $ns не найден."
    return
  fi

  echo "[*] Удаляем $ns..."
  ip netns delete "$ns" 2>/dev/null
  ip link delete "$veth_br" 2>/dev/null
  iptables -t nat -D POSTROUTING $rule 2>/dev/null

  remove_from_array NS_LIST "$ns"
  remove_from_array VETH_LIST "$veth_br"
  remove_from_array RULES "$rule"

  unset -f "$ns" 2>/dev/null
  remove_from_array ALIASES "$ns"

  echo "[+] Удалён: $ns"
  echo
}


list_namespaces() {
  if [ ${#NS_LIST[@]} -eq 0 ]; then
    echo "[!] Активных VPN нет."
  else
    echo "[*] Активные VPN:"
    for ns in "${NS_LIST[@]}"; do
      local id="${ns#vpn}"
      local subnet="${BASE_SUBNET}.${id}.0/24"
      echo "  - $ns  (subnet: $subnet)"
    done
  fi
  echo
}


status_namespaces() {
  if [ ${#NS_LIST[@]} -eq 0 ]; then
    echo "[!] Активных VPN нет."
    return
  fi
  if [ "$CURL_MISSING" -eq 1 ]; then
    echo "[!] Для 'status' нужен curl. Установи: sudo apt install curl"
    return
  fi

  echo "[*] Внешние IP по namespace:"
  for ns in "${NS_LIST[@]}"; do
    echo -n "  $ns → "
    $ns curl -s --max-time 5 ifconfig.me || echo -n "нет соединения"
    echo
  done
  echo
}


print_help() {
  cat <<EOF
[*] Команды:
  <число>       — создать VPN namespace с ID (пример: 1 → vpn1)
  list          — показать активные VPN
  kill <ID>     — удалить конкретный VPN (пример: kill 2)
  status        — показать внешний IP для каждого VPN
  help          — показать справку
  Ctrl+C        — удалить все созданные ресурсы и выйти

Примеры:
  1
  2
  vpn1 curl ifconfig.me
  vpn2 nmap -sT target.com
  status
  kill 1
EOF
  echo
}

# Banner + loop
echo "[*] Multi-VPN Manager (WAN_IFACE=$WAN_IFACE, BASE_SUBNET=$BASE_SUBNET)"
print_help

while true; do
  read -ra input -p "Введите команду: "
  cmd="${input[0]}"
  args=("${input[@]:1}")

  case "$cmd" in
    '' ) continue ;;
    help ) print_help ;;
    list ) list_namespaces ;;
    status ) status_namespaces ;;
    kill )
      if [[ "${#args[@]}" -ge 1 && "${args[0]}" =~ ^[0-9]+$ ]]; then
        kill_namespace "${args[0]}"
      else
        echo "Использование: kill <ID>"; echo
      fi
      ;;
    *)
      if [[ "$cmd" =~ ^[0-9]+$ ]]; then
        create_namespace "$cmd"
      else
        echo "Неизвестная команда. Введи 'help'."; echo
      fi
      ;;
  esac
done
