# Distribuir Overmark

Guía de firma, notarización y DMG para cuando exista el certificado.
El pipeline (`Scripts/build-app.sh`) ya está cableado: con el certificado
en el llavero, `Scripts/build-app.sh` detecta y firma automáticamente.

## Lo que falta comprar/tener (una vez)

1. Una cuenta del **Apple Developer Program** (99 USD/año).
2. En Xcode → Settings → Accounts → Manage Certificates:
   crear **Apple Developer ID Application** (expira al año; renovar).
   Verificar en la terminal:
   ```bash
   security find-identity -v -p codesigning
   #   1) ABC... "Developer ID Application: Tu Nombre (TEAMID)"
   ```
3. Para notarizar, crear el perfil de credenciales **una sola vez**
   (TEAMID es tu identifier de la cuenta de desarrollador):
   ```bash
   xcrun notarytool store-credentials OVERMARK_NOTARY \
       --apple-id tu-cuenta@example.com --team-id TEAMID
   ```
   (pide una App-Specific Password: appleid.apple.com → Seguridad).

## Pipeline ya listo

| Paso | Qué hace el script |
|---|---|
| Firma autodetectada | `Scripts/build-app.sh` busca un Developer ID en el llavero y lo usa; sin cert, firma ad-hoc con requisito estable (los permisos TCC sobreviven rebuilds) |
| Forzar identidad | `--sign "Developer ID Application: ..."` o `OVERMARK_SIGN_IDENTITY` |
| Forzar ad-hoc | `OVERMARK_SIGN_IDENTITY="-"` (útil en CI) |
| Release | firma con `--options runtime --timestamp` + entitlements (`Support/Overmark.entitlements`) |
| Notarización | con `OVERMARK_NOTARY_PROFILE=OVERMARK_NOTARY`: `notarytool submit --wait` + `stapler staple` al DMG |
| DMG | `build/Overmark.dmg` (comprime + symlink /Applications) |

## Flujo de distribución

```bash
Scripts/build-app.sh                       # firma sola si ya hay cert
OVERMARK_NOTARY_PROFILE=OVERMARK_NOTARY Scripts/build-app.sh   # + notarización
```

## Verificación antes de mandar

```bash
codesign --verify --deep --verbose=2 build/Overmark.app
spctl -a --verbose=2 build/Overmark.app        # Gatekeeper sobre la app
spctl -a -t install --verbose=2 build/Overmark.dmg   # si fue notarizada
xcrun stapler validate build/Overmark.dmg
```

## Notas

- La primera ejecución de la app masiva (installer-less, solo DMG) igual
  pasa por Gatekeeper: con ad-hoc pide confirmación de developer no
  identificado; con Developer ID + notarización, ni avisa.
- Los permisos TCC viven por bundle identifier y cdhash ad-hoc: el script
  escribe un requisito `designated => identifier "com.overmark.app"` que
  mantiene los permisos estables en builds ad-hoc. Con Developer ID el
  requisito nativo (`anchor apple`) ya es estable.
- El GIF animado y el changelog quedan en el roadmap; este documento solo
  cubre la tubería de distribución.
