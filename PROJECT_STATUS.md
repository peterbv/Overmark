# Presentify — Estado del proyecto

_Fecha: 2026-10-21 · Rama `main` · Estado: **FUNCIONAL** ✅_

App de anotación en pantalla para macOS (barra de menú, modo accesorio), Swift Package
(swift-tools 6.0, macOS 14+), sin sandbox. Creada para anotar **encima de vivo** durante
presentaciones, sin congelar el escritorio.

---

## Qué funciona hoy

### Núcleo
- Entrar/salir del modo presentación: **⌘⇧A**, menú de la barra o botón rojo "Listo".
  **ESC** termina siempre (salida garantizada).
- Superposiciones = **lienzos transparentes** sobre el escritorio vivo: nunca se ve
  una foto estática de la pantalla; las anotaciones se ven en el momento.
- Modo de clics: por defecto los overlays **dejan pasar los clics** al Mac
  (Dock, Finder, apps…). Mantené **⌥** para dibujar. Se puede cambiar a modo
  "captura todo" en Preferencias → Herramientas. Si falta Accesibilidad, la barra
  muestra un chip ámbar **"modo de captura"** que abre los Ajustes al tocarlo.

### Barra flotante
- 7 herramientas (lápiz, resaltador, flecha, rectángulo, elipse, texto, número de paso),
  paleta + grosor, deshacer/rehacer/limpiar, 3 efectos, pausa, engranaje, "Listo".
- **Arrastrable** por la moving de la parte superior y con **snap magnético a las 4 esquinas**.
- **Auto-ocultar** (esta es la entrada): se colapsa a una pestaña al soltar el cursor,
  reaparece al pasar por encima o arrastrar la pestaña.
- Botón **?** → panel flotante de atajos de teclado (es/no según idioma).

### Efectos de cursor
- **Resaltador**: aro configurable (radio 20–80, color de la paleta).
- **Foco (spotlight)**: agujero 100–450 + atenuación 0–100%.
- **Lupa**: contenido **EN VIVO** (~3fps, solo la pantalla del cursor, excluye ventanas propias).
  Límites: contenido DRM se ve negro; ≤320ms al cambiar de pantalla.

### Extras
- **Español por defecto**, inglés y automático; cammbio en Preferencias → General → Idioma
  (se persiste). Toda la UI traducida (menú, barra, ajustes, onboarding, editor, errores).
- Icono generado por código (Scripts/make-icon.swift): monitor + degradado índigo→violeta.
- Permisos honestos: estado **Denegado** visible (ya no se confunde con "Sin configurar").

### Atajos
| Acción | Tecla |
|---|---|
| Entrar / terminar presentación | ⌘⇧A · ESC |
| Resaltador / Foco / Lupa | ⌘⇧F / ⌘⇧D / ⌘⇧G |
| Pausar | ⌘⇧S |
| Deshacer / Rehacer | ⌘⌥Z / ⌘⌥⇧Z |
| Copiar / Guardar captura | ⌘⇧C / ⌘⌥⇧S |
| Salir de Presentify | ⌘⌥Q |

---

## Historia de fixes (commits)

1. `81879ca` baseline pre-auditoría.
2. `b20df63` auditoría P0/P1 + barra flotante: export sin doble dibujo (se excluyen las
   ventanas propias de las capturas), contentsScale Retina, event tap sigue arrastres,
   franja de menú clicable, rebuilds serializados, Settings arriba de los overlays,
   herramientas fantasma fuera del picker, permiso denegado visible, multimonitor por DisplayID.
3. `e82b5b6` **ESC** como salida garantizada (el bundle viejo daba la sensación de "no hay escape").
4. `29bd8bb` crash del observer del menú (puente Combine→AsyncSequence, "Received an output
   without requesting demand") reemplazado por `.receive(on: RunLoop.main).sink`.
5. `e12ca3c` español completo + pasaje de clics real a nivel servidor (`ignoresMouseEvents`
   monitoreado con event tap de flagsChanged) + icono nuevo.
6. `09cfdf6` crash al apagar efectos (autorelease diferido de la ventana: `isReleasedWhenClosed=false`),
   resaltador solo en la pantalla del cursor, flip contra pantalla primaria, barra arrastrable,
   telemetría de diagnóstico.
7. `d229a23` **causa real del "congelamiento"**: la captura era una subcapa encima del canvas
   → eliminada; overlays vivos; iniciar ya no pide Grabación de pantalla; aviso si no hay pantallas.
8. `22b7d71` botones de efectos en la barra + personalización de aro y foco.
9. `e3560ba` barra arrastrable de verdad (grip + `performDrag`; el fondo SwiftUI no la movía).
10. `d465d62` snap a esquinas + auto-ocultar (pestaña) + panel de atajos.
11. `e8be354` lupa EN VIVO (~3fps) en vez de captura estática.

`swift build` limpio · `swift test` **36/36** (8 suites) · espondió en cada ronda una
sonda (PRESENTIFY_PROBE=1) que ejercita el flujo completo headless.

## Cómo construir y correr

```bash
swift build && swift test
bash Scripts/build-app.sh          # → build/Presentify.app + build/Presentify.dmg (firma ad-hoc)
open build/Presentify.app
```

- Firma ad-hoc: cada rebuild puede hacer que macOS **vuelva a pedir** Grabación de
  pantalla/Accesibilidad (el TCC se revalida por cdhash). Conceder una vez por build.
- Iniciar presentación/anotar NO requiere Grabación de pantalla; copiar/guardar y el
  fondo de la lupa sí (degradan con gracia si falta).

---

## Backlog conocido (no bloquea uso)

- Texto: una sóla línea; los bounds guardados no coinciden exactamente con el render.
- Sin persistencia de documentos ni borrado por clic-derecho (undo/limpiar cubre lo básico).
- Los overlays no reaccionan en vivo a cambios de resolución/conexión de pantallas.
- Copiar/guardar usa solo el primer display (multimonitor exporta una sola pantalla).
- Lupa ~3fps y solo la pantalla del cursor (extra pantalla queda con snapshot de entrada).
- Atajos fijos (no configurables por el usuario).
- Escena `Settings` de SwiftUI muerta (se usa ventana propia) — código vivo pero residual.

## Si lo subimos a GitHub (checklist para cuando toque)

- [ ] Elegir nombre final del bundle/app y LICENSE (¿MIT?).
- [ ] README bilingüe (es/en) con GIFs de la barra, efectos y lupa.
- [ ] Firma real: sustituir ad-hoc por "Developer ID Application" (o instruir
      clic-derecho → Abrir para sortear Gatekeeper) y explicar el FAQ de permisos TCC.
- [ ] CI: GitHub Actions en runner macOS (`swift build && swift test`).
- [ ] Releases con DMG adjunto + `codesign --verify --deep` y etiquetas versionadas.
- [ ] Añadir `git remote`, primer push, y proteger main.
- [ ] Considerar actualizador automático (Sparkle) si hay usuarios reales.
