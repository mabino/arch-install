# arch-install
Arch Linux installation.

This script targets a Lenovo Thinkpad T470s, but is readily generalizable to a device that boots via UEFI, has Secure Boot, and a TPM.

## Known Issues

* The post-install systemd service is not fully tested and working.  The script is a placeholder for the TPM enrollment via `sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7  /dev/gpt-auto-root-luks`, a one-time command that currently requires a manual step.
* The `useradd` step isn't functioning as expected, dumping the hash into the `passwd` file instead of `shadow`.  Running it interactively works, but that is yet another manual step.
* I'd rather hash the encrypted drive password like with a proper one for the user account than store it in the configuration file in plain text, even if it is only for setup purposes; I haven't found a way to do that yet.
* I'd like to install `yay` as part of this automated step but haven't gotten around to it yet.
* The T470s has a fingerprint sensor, which you can get to work via [python-validity](https://github.com/uunicorn/python-validity).
