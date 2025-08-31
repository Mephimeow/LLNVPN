#!/bin/bash
set -euo pipefail

#Globals
NS_LIST=()       # список namespace
WRAPPERS=()      # список обёрточных файлов
CLEANED_UP=false


cleanup() {
  if [ "$CLEANED_UP" = true ]; then
    return
  fi
  CLEANED_UP=true

  echo "🧹 Очистка..."
  for ns in "${NS_LIST[@]}"; do
    ip netns del "$ns" 2>/dev/null || true
  done

  for wrapper in "${WRAPPERS[@]}"; do
    rm -f "$wrapper"
  done

  echo "✅ Всё очищено"
}

cleanup_and_exit() {
  cleanup
  exit 0
}

trap cleanup_and_exit INT TERM
trap cleanup EXIT


WAN_IF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
if [[ -z "$WAN_IF" ]]; then
  echo "❌ Не найден WAN интерфейс"
  exit 1
fi
echo "🌐 WAN-интерфейс: $WAN_IF"

BASE_SUBNET="10.200.0.0/16"
echo "📡 Базовая подсеть: $BASE_SUBNET"

# Включаем IP forward
if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]]; then
  echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null
  echo "⚡ IP Forward включен"
fi


create_namespace() {
  local id="$1"
  local ns="vpn$id"
  local veth_host="veth_${ns}_host"
  local veth_ns="veth_${ns}_ns"
  local subnet="10.200.$id.0/24"
  local ip_host="10.200.$id.1/24"
  local ip_ns="10.200.$id.2/24"

  echo "➕ Создаю $ns"

  ip netns add "$ns"
  ip link add "$veth_host" type veth peer name "$veth_ns"
  ip link set "$veth_ns" netns "$ns"

  ip addr add "$ip_host" dev "$veth_host"
  ip link set "$veth_host" up

  ip netns exec "$ns" ip addr add "$ip_ns" dev "$veth_ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip route add default via 10.200.$id.1

  iptables -t nat -A POSTROUTING -s 10.200.$id.0/24 -o "$WAN_IF" -j MASQUERADE

  # обёртка для обычного пользователя
  local wrapper_user="/usr/local/bin/$ns"
  cat > "$wrapper_user" <<EOF
#!/bin/bash
exec sudo -u "$USER" /sbin/ip netns exec $ns "\$@"
EOF
  chmod +x "$wrapper_user"

  # обёртка для root
  local wrapper_root="/usr/local/bin/${ns}-root"
  cat > "$wrapper_root" <<EOF
#!/bin/bash
exec sudo /sbin/ip netns exec $ns "\$@"
EOF
  chmod +x "$wrapper_root"

  NS_LIST+=("$ns")
  WRAPPERS+=("$wrapper_user" "$wrapper_root")

  echo "✅ Namespace $ns готов."
  echo "   Используй: $ns <команда> (от юзера)"
  echo "           или: ${ns}-root <команда> (от root)"
  echo "   ⚠️ Убедись, что в sudoers есть правило:"
  echo "     $USER ALL=(ALL:ALL) NOPASSWD: /sbin/ip netns exec *"
}

list_namespaces() {
  echo "🌐 Текущие VPN namespace:"
  for ns in "${NS_LIST[@]}"; do
    echo " - $ns (/usr/local/bin/$ns, /usr/local/bin/${ns}-root)"
  done
}

status_namespaces() {
  for ns in "${NS_LIST[@]}"; do
    echo "🔎 [$ns]"
    if command -v "$ns" &>/dev/null; then
      echo -n "  IP: "
      "$ns" curl -s --max-time 5 ifconfig.me || echo "нет ответа"

      echo -n "  Default route: "
      if ! "$ns" ip route show default 2>/dev/null | awk '{print $3; exit}'; then
        echo "нет маршрута"
      fi
    else
      echo "  обёртки отсутствуют"
    fi
  done
}

print_help() {
  echo -e "📖 Доступные команды:
  <число>   — создать VPN namespace (например: 1 → vpn1 и vpn1-root)
  list      — показать созданные VPN
  status    — проверить IP и маршрут VPN
  quit|exit — выйти из скрипта
  help      — показать эту справку"
}


print_help


while true; do
  read -rp "Введите команду (help для справки): " cmd
  case "$cmd" in
    [0-9]*) create_namespace "$cmd" ;;
    list)   list_namespaces ;;
    status) status_namespaces ;;
    help)   print_help ;;
    quit|exit) break ;;
    *) echo "❓ Неизвестная команда (см. help)" ;;
  esac
done
