# Mac app guidelines

- After any change here, rebuild with `scripts/build.sh` before finishing, signed and notarized like the published build: `DEVELOPER_ID=89A1DD63507AAD8592A9E56668F15A22AB42A939 NOTARY_PROFILE=devnull scripts/build.sh`. Check that `DevNull.json` says `"notarized": true` before finishing. It writes `public/downloads/DevNull.dmg` and `public/downloads/DevNull.json` into the website checkout at `../dev-null.sh`: leave both in that working tree to ship with the change, never restore or discard them.
