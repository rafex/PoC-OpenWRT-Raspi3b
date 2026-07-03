# Casos de Uso

Esta carpeta documenta flujos operativos completos construidos con las herramientas actuales del proyecto. La referencia exhaustiva de comandos sigue en [Uso de Just](../JUST.md); aquí se documenta qué hacer en escenarios concretos.

## Ejemplos

| Caso | Archivo |
|------|---------|
| Uplink WiFi 2.4 GHz + AP 5 GHz | [examples/wifi-uplink-24ghz-ap-5ghz.md](examples/wifi-uplink-24ghz-ap-5ghz.md) |
| Reservas DHCP e inventario de clientes | [examples/static-dhcp-and-inventory.md](examples/static-dhcp-and-inventory.md) |
| Diagnóstico de comunicación LAN | [examples/lan-connectivity-doctor.md](examples/lan-connectivity-doctor.md) |
| Portal cautivo local | [examples/captive-portal-local.md](examples/captive-portal-local.md) |
| Proxy Tor transparente para `.onion` | [examples/tor-onion-transparent-proxy.md](examples/tor-onion-transparent-proxy.md) |
| Port forwarding del proxy SOCKS de Tor | [examples/socks-forward-to-raspi.md](examples/socks-forward-to-raspi.md) |
| Backup, build y actualización segura | [examples/backup-build-update.md](examples/backup-build-update.md) |

## Convenciones

- El router OpenWrt se asume en `192.168.1.1`.
- El entorno por defecto es `prod`.
- Los comandos `router-*` se ejecutan desde el repo en la máquina que tenga SSH hacia el router.
- En recipes con `*args`, usa flags como `--ip 192.168.1.1`.
- En recipes posicionales documentadas así, pasa los valores por posición.
