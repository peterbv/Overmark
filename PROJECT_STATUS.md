# Overmark — Estado del proyecto

_Fecha: 2026-10-22 · Rama `main` · Estado: **FUNCIONAL** ✅_

App de anotación en pantalla para macOS (barra de menú, modo accesorio), Swift Package
(swift-tools 6.0, macOS 14+), sin sandbox. Creada para anotar **encima de vivo** durante
presentaciones, sin congelar el escritorio.

---

## Qué funciona hoy

### Núcleo
- Entrar/salir del modo presentación: **⌘⇧A** (configurable en Preferencias → Atajos),
  menú de la barra o botón rojo "Listo".
  **ESC** termina siempre (salida garantizada).
- **Novedades de esta ronda**:
  - **Clic derecho borra la anotación** que está debajo del cursor (sin menú
    contextual; undo la restaura). Hit-test en el núcleo, probado.
  - **Texto multilínea** (⏎ salta de línea, ⌘⏎ confirma); bounds y render
    comparten las mismas constantes de layout.
  - **Copiar/guardar captura** abraza todo el escritorio multimonitor en una
    sola imagen compuesta por pantalla.
  - **Atajos configurables**: nueva pestaña Atajos en Preferencias graba la
    combinación nueva (debe incluir ⌘, detecta conflictos), persiste solo los
    overrides y la chuleta de la barra refleja siempre los atajos vivos.
  - **Grabación por ventana viva**: el track se adopta al arrancar pero el
    stream reescala el contenido en ambas direcciones y el burn-in sigue la
    geometría viva por frame — mover o redimensionar la ventana grabada ya
    no desplaza las anotaciones ni deja bandas de recorte.
  - **Renombre Presentify → Overmark** (todo el repo, módulos y bundle id).
    Motivo: Presentify es un producto comercial existente (7 años, App Store,
    Setapp, Homebrew) con el nombre y dominio ocupados; Overmark está libre
    en la categoría de anotación de pantalla y overmark.app sin registrar.
    La única colisión (un SaaS de agencias IA) es de otro rubro. El cambio
    de bundle id hace que la app vuelva a pedir Permisos una única vez.
  - **Aro configurable**: forma (círculo, squircle o rombo), grosor de borde
    (1–12 pt) y opacidad del relleno (0–80%), además del radio y color previos.
  - **Ondas de clic**: animación al pulsar (variante para el clic derecho),
    desactivable en Preferencias → Cursor → Animación de clic.
  - **Auto-borrado temporizado**: los trazos se desvanecen solos tras un
    retardo configurable (3–60 s). No toca nunca los números de paso y el
    desvanecido no ensucia el deshacer.
  - **Edición de texto in situ**: con la herramienta Texto, un clic sobre un
    texto ya escrito lo reabre para corregirlo (mismo id/color/grosor).
  - **Preferencias persistentes**: herramienta, color, relleno, degradado,
    auto-borrado y efectos de cursor se recuerdan entre sesiones; datos
    corruptos caen a los valores de fábrica sin ruido.
  - **Trazo degradado**: los trazos funden el color inicial con uno final a
    lo largo de la línea (Preferencias → Herramientas; el resaltador
    permanece sólido, y los números de paso/texto no se degradan).
  - **Colores favoritos**: el "+" de la paleta (barra y Preferencias) abre
    el panel de color; hasta 8 colores propios, deduplicados y persistentes.
  - **Relleno por figura**: el relleno se decide al dibujar cada figura y
    viaja con ella — export y grabación reproducen exactamente lo que el
    canvas mostró (antes dependía del estado global del momento).
- Superposiciones = **lienzos transparentes** sobre el escritorio vivo: nunca se ve
  una foto estática de la pantalla; las anotaciones se ven en el momento.
- Modo de clics: por defecto los overlays **dejan pasar los clics** al Mac
  (Dock, Finder, apps…). Mantené **⌥** para dibujar. Se puede cambiar a modo
  "captura todo" en Preferencias → Herramientas. Si falta Accesibilidad, la barra
  muestra un chip ámbar **"modo de captura"** que abre los Ajustes al tocarlo.
- **Alcance de la anotación**: la barra tiene un selector de pantallas —
  "Todas las pantallas" o solo una (útil con un proyector espejado: anotás en
  la copia limpia). Se persiste y el cambio aplica en caliente. Si conectás o
  desconectás pantallas en plena sesión, los lienzos se reconstruyen solos y
  las anotaciones sobreviven (aviso discreto + barra re-acomodada).

### Barra flotante
- 7 herramientas (lápiz, resaltador, flecha, rectángulo, elipse, texto, número de paso),
  paleta + grosor, deshacer/rehacer/limpiar, 3 efectos, selector de pantallas,
  botón de grabación (rojo con cronómetro mientras graba; "terminando" deshabilitado;
  chip verde "Grabación guardada" que abre Finder al terminar), pausa, engranaje, "Listo".
- El ítem del menú de la barra tiene la misma pantalla de anotación como submenú
  con marcas de verificación (disponible estando en modo anotación).
- **Arrastrable** por la banda de la parte superior y con **snap magnético a las 4 esquinas**.
- **Auto-ocultar** (esta es la entrada): se colapsa a una pestaña al soltar el cursor,
  reaparece al pasar por encima o arrastrar la pestaña.
- Botón **?** → panel flotante de atajos de teclado (es/no según idioma).

### Efectos de cursor
- **Resaltador**: aro configurable (radio 20–80, color de la paleta, forma
  círculo/squircle/rombo, grosor de borde y opacidad del relleno).
- **Animación de clic**: una onda marca cada pulsación (izquierda y derecha)
  en la pantalla del cursor. Requiere alguna función de cursor activa —
  es el escenario de sus ventanas.
- **Foco (spotlight)**: agujero 100–450 + atenuación 0–100%.
- **Lupa**: contenido **EN VIVO** (~3fps, solo la pantalla del cursor, excluye ventanas propias).
  Límites: contenido DRM se ve negro; ≤320ms al cambiar de pantalla.

### Grabación de la presentación
- **⌘⇧R** o el botón rojo de la barra: graba la presentación completa con
  `SCStream → AVAssetWriter` (.mov H.264/HEVC, 30/60 fps) en
  `~/Movies/Overmark` (carpeta configurable en General; `"(2)"` si hay colisión).
- Micrófono **opcional** (toggle en General → Grabación; pide el permiso recién
  al activarlo; denegado → graba sin sonido y lo avisa).
- **Pantalla a grabar** elegible (principal o por nombre). El módulo
  `OvermarkRecorder` escribe todo el display menos las ventanas propias
  (barra, cheatsheet, ajustes, editor): el resto queda en la película.
- **Objetivo: pantalla completa o una ventana.** En modo ventana el stream
  sigue esa ventana con `SCContentFilter(desktopIndependentWindow:)` y las
  anotaciones se dibujan dentro del video (burn-in con `AnnotationRenderer`;
  la captura de una sola ventana no contendría las capas). El burn-in sigue
  al documento en vivo: el auto-borrado temporizado y la edición in situ
  del texto también quedan grabados. El track es de
  tamaño fijo (un writer vivo no redimensiona pista), pero el stream escala
  el contenido hacia arriba y abajo (`scalesToFit`, macOS 14+) y el burn-in
  lee la geometría viva de cada frame (`SCStreamFrameInfo`:
  `ScreenRect`/`ContentRect`, autocarlibrados contra la geometría del
  arranque) — las anotaciones siguen pegadas a la ventana aunque la muevan
  o la redimensionen. Los efectos dedicados (spotlight/desenfoque/laser)
  no quedan dibujados en este modo. Un track realmente variable exigiría
  `SCRecordingOutput` (macOS 15), que no entrega frames por callback y
  con ello ciega el burn-in — descartado en favor del track fijo escalado.
- Salir (ESC/"Listo"/⌘Q) **finaliza siempre el archivo** — nunca queda corrupto.
  Si la grabación se corta o sale vacía, la barra lo dice en lugar de callar.

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
| Grabar / detener la grabación | ⌘⇧R |
| Pausar | ⌘⇧S |
| Deshacer / Rehacer | ⌘⌥Z / ⌘⌥⇧Z |
| Copiar / Guardar captura | ⌘⇧C / ⌘⌥⇧S |
| Salir de Overmark | ⌘⌥Q |

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
12. `04c8bcf` ronda 2026-10-22: borrado por clic derecho, texto multilínea,
    export multimonitor en una sola imagen y atajos configurables con
    persistencia de overrides (nueva pestaña Atajos en Preferencias).
13. `049f4ab` grabación por ventana viva: track fijo con escalado del
    stream (`scalesToFit`) y burn-in que sigue la geometría por frame de
    `SCStreamFrameInfo` (ScreenRect/ContentRect autocalibrados); la caja
    imaginada `scalableScreenCaptureIfNeeded` no existe en el SDK —
    `SCRecordingOutput` (que no entrega frames) fue descartado.
14. `5a1d676` renombre Presentify → Overmark (marca, módulos SwiftPM,
    bundle id `com.overmark.app`) + `build/` sacado del tracking (estaba
    comiteado por accidente, binario incluido). Chequeo de marca previo:
    sin colisión en la categoría; overmark.app libre.
15. `3f4f648` ronda de pulido: aro con formas/borde/relleno configurables,
    ondas de clic (izquierda y derecha, con toggle), auto-borrado
    temporizado (desvanece 5×120 ms y remueve sin ensuciar el undo; los
    números de paso jamás se desvanecen) y edición in situ del texto con
    la herramienta Texto.
16. `b2e45c5` ronda de preferencias: herramienta y efectos de cursor
    persistidos (blob JSON tolerante a corrupción), trazo degradado en 8
    tramos, favoritos de color vía `NSColorWell` + panel del sistema y
    relleno por figura (export/grabación fieles al canvas).

`swift build` limpio · `swift test` verde: **95** pruebas Swift Testing (16 suites) +
**24** XCTest del grabador (frames sintéticos → `.mov` real; geometría de
ventana y mapeo por frame incluidos). Cada ronda corre una sonda
(OVERMARK_PROBE=1) que ejercita el flujo completo headless.

## Cómo construir y correr

```bash
swift build && swift test
bash Scripts/build-app.sh          # → build/Overmark.app + build/Overmark.dmg (firma ad-hoc)
open build/Overmark.app
```

- Firma ad-hoc: cada rebuild puede hacer que macOS **vuelva a pedir** Grabación de
  pantalla/Accesibilidad (el TCC se revalida por cdhash). Conceder una vez por build.
- Iniciar presentación/anotar NO requiere Grabación de pantalla; copiar/guardar y el
  fondo de la lupa sí (degradan con gracia si falta).

---

## Backlog conocido (no bloquea uso)

- Texto: los bounds guardados siguen siendo aproximados (por diseño: anclan
  hit-test generoso y el filtro de pantalla, no métricas exactas de glifos).
- Sin persistencia de documentos (undo/limpiar + borrado por clic derecho
  cubren lo básico).
- Lupa ~3fps y solo la pantalla del cursor (extra pantalla queda con snapshot de entrada).
- Grabación por ventana: no incluye los efectos dedicados; el track se fija
  al arrancar pero el stream reescala el contenido y el burn-in sigue la
  geometría viva (una ventana que cambia de aspecto puede estirarse
  levemente — medido, no bandas).
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
