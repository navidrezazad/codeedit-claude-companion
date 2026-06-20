# Security Notes

CodeEdit Claude Companion is a personal productivity prototype. It should be treated as trusted-device software, not as a hardened remote-access product.

## Recommended Use

- Pair only with devices you control.
- Prefer same-network use or a private tunnel such as Tailscale or VPN.
- Do not expose the Mac bridge directly to the public internet.
- Rotate the remote passcode if a device is lost or shared.
- Avoid displaying tokens, passcodes, private IPs, or customer data in public screenshots.

## Current Protections

- The iOS app authenticates to the Mac bridge with a configured passcode.
- The app supports local Bonjour discovery and direct IP reconnect.
- Remote terminal sessions remain hosted on the Mac.
- Claude Markdown helper invocations use `claude-opus-4-8` with medium effort and tool use disabled; the Mac bridge writes returned Markdown output.

## Known Limitations

- The networking layer is a prototype bridge, not a complete zero-trust remote-access layer.
- Direct public-IP access depends on external network configuration and should be protected by VPN/tunnel/firewall rules.
- The current project has not gone through a formal security review.
