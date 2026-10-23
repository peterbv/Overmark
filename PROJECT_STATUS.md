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
  - **Persistencia de documentos**: lo dibujado queda en un autoguardado
    (debounce 0,6 s + flush al salir/terminar) y reaparece al volver a
    abrir Overmark; la nueva pestaña **Documentos** en Preferencias guarda
    la sesión con nombre, la restaura o la elimina de una lista. Nombres
    saneados y sin colisiones; archivos corruptos se
    descartan sin ruido.
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
    no desplaza las anotaciones ni deja bandas de recorte. Los efectos de
    cursor (anillo, spotlight, lupa, ripples) también se queman por frame
    con la misma matriz; la lupa muestra el contenido limpio de la ventana
    (snapshot previo a las anotaciones).
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
  - **Auto-borrado temporizado**: los trazos (formas y textos incluidos) se
    desvanecen solos tras un retardo configurable (3–60 s). Los números de
    paso también se desvanecen, con contador monótono: un número ya visto no
    se reutiliza hasta que la pizarra se limpia o se restaura un documento.
    El desvanecido no ensucia el deshacer.
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
  (Dock, Finder, apps…). Mantené la **tecla de dibujo** para anotar — **⌥**
  por defecto, **⌃/⌘** seleccionables en Preferencias → Herramientas y
  aplicadas en caliente (chip dinámico en la barra). Se puede cambiar a modo
  "captura todo" en la misma pestaña. Si falta Accesibilidad, la barra
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
- **Lápiz de bloqueo** (`pencil.tip`, junto a pausa): un clic alterna entre
  dibujar con cada clic (sin mantener la tecla de dibujo) y el modo
  tecla-dibujar; el chip "captura todo" también alterna con un tap.
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
- **Lupa**: contenido **EN VIVO**, excluye ventanas propias. Tamaño de lente
  80–420 pt, factor 1–6× y forma círculo/squircle ya configurables; la
  cadencia de refresco es elegible (normal ~3 fps / fluida ~8 fps, aplica al
  siguiente tick). Con el espejo activo, las pantallas que no hospedan el
  puntero muestran la misma lente al punto proporcional (mapeo
  `mirrorLensPlacement`); apagarlo reconstruye y devuelve el snapshot propio.
  Límites: contenido DRM se ve negro; ≤320ms (≤1 tick del rate elegido) al
  cambiar de pantalla.
- **Puntero láser**: punto brillante (halo + núcleo + fleca blanca, color y
  tamaño 2–14 pt configurables) con cola que se apaga en ~0,7 s. Toggled
  desde la barra (4º efecto) o Settings → Cursor; la cola muestrea cada
  movimiento y se apaga con un ticker propio cuando el cursor se detiene.

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
  o la redimensionen. Los efectos dedicados (anillo/spotlight/lupa/láser/
  ripples) también se queman por frame en este modo (ver ítems 22 y 23).
  Un track realmente variable exigiría
  `SCRecordingOutput` (macOS 15), que no entrega frames por callback y
  con ello ciega el burn-in — descartado en favor del track fijo escalado.
- Salir (ESC/"Listo"/⌘Q) **finaliza siempre el archivo** — nunca queda corrupto.
  Si la grabación se corta o sale vacía, la barra lo dice en lugar de callar.

### Pizarra dedicada
- Estado del overlay, **no un modo nuevo**: con la sesión activa, la pizarra
  con un clic, ☑ del menú o ⌘⇧B cubre las pantallas del scope con un
  tablero opaco (blanco o negro, tono persistido en Preferencias →
  Herramientas → Pizarra) y anota encima sin ninguna app debajo.
- Mientras la pizarra está en pantalla todo clic dibuja (el gate de la tecla
  de dibujo no aplica); **pausar** (⌘⇧S) pliega el lienzo — el desktop vuelve a ser
  interactivo y al reanudar reaparece; **salir** la apaga para la próxima
  sesión. Cambiar el tono se aplica al instante, sin reconstruir ventanas.
- Las capturas multi-monitor componen el relleno del tablero: copiar o
  guardar muestran la pizarra tal como la vio el público, no el desktop
  escondido detrás.

### Congelar pantalla
- Otro estado del overlay, hermano de la pizarra (sesión activa, botón
  `snowflake` de la barra, ☑ del menú o ⌘⇧P): se captura **una vez** cada
  pantalla del scope — excluyendo las ventanas propias — y las canvases
  pintan ese still detrás de las anotaciones: el fondo queda quieto para
  anotar encima mientras las apps de abajo siguen corriendo.
- Excluyente con la pizarra en ambos sentidos (elegir uno suelta el otro);
  **pausar** pliega el still como pliega el lienzo; **salir** lo suelta.
- Las capturas componen el frame congelado (`frozen:` en el compositor,
  con precedencia sobre el relleno): copiar y guardar muestran el still
  tal como lo vio el público, con las anotaciones encima.

### Mover y recolorear anotaciones (marquee)
- Botón de selección en la barra (estado del overlay, sesiones activas):
  marquee por intersección de límites; arrastrar una selección la mueve
  con clamp para que nunca salga de la pantalla; la paleta recolorea lo
  seleccionado (color sólido, limpia el gradiente); la basura borra lo
  seleccionado — cuando no hay selección limpia todo, como siempre.
- Un gesto = un undo (mutadores batch en `AnnotationDocument`):
  `update(_:recordHistory:)` y `remove(ids:recordHistory:)`.
- Elegir una herramienta de dibujo o apagar el modo limpia la selección;
  también se poda sola si el documento cambia debajo.

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
| Pizarra | ⌘⇧B |
| Congelar pantalla | ⌘⇧P |
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
17. `eac4273` persistencia de documentos: `SessionArchive` en el núcleo
    (snapshot v1 con anotaciones + layout de pantallas + fecha; JSON
    atómicos en `Application Support/Overmark/Documents`), autosave.json
    propio (debounce 0,6 s en el coordinator, flush al salir del modo y
    al terminar la app, borrado si el lienzo queda vacío) y restauración
    al arrancar; pestaña **Documentos** en Preferencias con guardar con
    nombre, restaurar y eliminar; 10 tests nuevos del archivo de sesión.
18. Botón lápiz de bloqueo en la barra (`pencil.tip` junto a pausa):
    alterna `holdOptionToDraw` — tintado dibuja con cada clic sin ⌥,
    apagado vuelve al modo ⌥-dibujar; el chip "captura todo" pasa de
    abrir Settings a alternar directamente. Cambio solo de UI sobre el
    flag persistido (sin tests nuevos, suite intacta).
19. Pizarra dedicada como estado del overlay (`b39d442`): el canvas pinta
    el tablero opaco y reclama cada clic; tono blanco/negro persistido
    (`BoardStyle`), botón en barra + ☑ en menú + ⌘⇧B, pausa pliega el
    lienzo y el compositor de capturas añade el relleno del tablero
    (`boardFill` → `backdrop`). 4 tests nuevos del estilo del tablero.

20. Auto-borrado de números de paso: las formas y el texto ya se
    desvanecían (la nota del roadmap era imprecisa) — el cambio real fue
    meter los sellos al temporizador y volver el contador monótono
    (`stepNumberFloor`: un número mostrado no se reemite hasta que se
    limpia o se restaura un documento). Footnote de Auto-borrado y tests
    actualizados.

21. Tecla de dibujo configurable: el gate hold-to-draw se desacopla del
    ⌥ fijo — **⌥/⌃/⌘** en Preferencias → Herramientas (persistido),
    aplicado en caliente: el tap de flagsChanged cambia el bit rastreado
    (`ModifierKeyMonitor.setMask`, renombrado desde `OptionKeyMonitor`), los
    lienzos re-chequean `NSApp.currentEvent` contra la máscara elegida y el
    chip de la barra muestra el símbolo real. Preferencia separada
    (`Overmark.drawingModifier`) para no perturbar el blob de ToolSettings.

22. Efectos de cursor dentro de la grabación de ventana: el dibujo de los
    efectos vive ahora en `CursorEffectRenderer` (Capture, CG-puro) — la
    ventana on-screen delega en él y el recorder lo llama por frame con la
    misma matriz de anotaciones, tras un snapshot *limpio* (la lupa muestra
    la ventana sin anotaciones). Nuevo box thread-safe `CursorEffectFrame`
    recepciona settings/puntero/clics; el spotlight quema con clip even-odd
    (el blend `.clear` habría ennegrecido el buffer opaco). Display ya
    mostraba los efectos (ventanas en cinta); 15 tests nuevos de box,
    formas, spotlight por píxel, ripple-math y recorte de lupa.

23. Puntero láser (del banco de ideas): punto brillante con cola que se
    apaga en ~0,7 s. Descartado el encaje de `AnnotationTool.laserPointer`
    (dormido en el enum): un láser es transitorio y no pertenece al
    documento. En su lugar, efecto de cursor completo: renderer
    (`drawLaserDot`/`drawLaserTrail`), muestreo de la cola en el box del
    recorder (prune 0,75 s, tope 64), burn en la grabación de ventana con
    la misma matriz, toggle en la barra (4º botón de efectos) y Settings.
    Cambio estructural: el `decode` de `CursorEffects` es tolerante
    (`decodeIfPresent` en todos los campos) — agregar un campo ya no
    descarta las preferencias guardadas del usuario. 11 tests nuevos
    (box de trail, decode de blobs viejos, fade-math, píxeles del dot).

24. Lupa configurable: tamaño de lente 80–420 pt (slider nuevo; el campo
    `zoomSize` ya persistía pero sin UI), tasa de refresco elegible
    (`LensRefreshRate` normal/fluida con intervalos 0,32/0,12 s releídos por
    tick) y espejo en múltiples pantallas: `lensSourceScreen` en la vista y
    mapping proporcional `mirrorLensPlacement` (renderer, CG-puro) — las
    pantallas sin puntero muestran la misma lente donde corresponde; al
    apagarlo un rebuild devuelve el snapshot propio de cada pantalla. El
    toggle solo aparece con más de una pantalla. 5 tests nuevos (defaults +
    round-trip incl. campos nuevos; identidad, mapeo cruzado y guards del
    placement).

25. Barra anclada que se fuga fuera del escritorio (`2c050fc`): colapsar
    pegaba la pestaña a los bordes de la barra, pero reexpandir crecía
    desde el *origen* de la pestaña y el clamp solo prometía 120 pt
    visibles — cada ciclo de anclaje empujaba la barra un ancho completo
    más afuera hasta que la propia pestaña quedaba inalcanzable. La
    expansión ahora invierte el colapso (la esquina ancla devuelve la
    barra al punto exacto de donde se plegó), la pestaña se clampa
    íntegra dentro de las pantallas al plegarse y un clamp de
    visibilidad completa cubre rearrangements de displays.

26. Congelar pantalla (desde el banco de ideas): estado del overlay
    hermano de la pizarra — el canvas gana `backdropImage` (dibujado
    después del relleno del tablero, antes del renderer) y el
    coordinator captura una vez por display con el `ScreenCaptureService`
    (sin ventanas propias) para repartir stills por display. Excluyente
    con la pizarra en ambos sentidos; pausa pliega el still
    (`setFreezeVisible`); captura/captura+guardar compositan el frame
    congelado (`composited(frozen:)` + `desktopImage(frozenFill:)`).
    Botón `snowflake` en la barra, ☑ del menú, ⌘⇧P; el probe reporta si
    el grant TCC fresco del binario falta. 3 tests nuevos de compositing
    (el still reemplaza la captura, gana sobre el relleno, no-op sin
    frozen).

27. Mover y recolorear anotaciones (marquee, migrado del banco): modo de
    selección como estado del overlay — gesto de marquee por intersección,
    arrastre con clamp, recolor desde la paleta existente
    (`with(color:)`, limpia gradiente), basura que decide entre borrar
    selección o limpiar todo. 6 tests sumados (transform de solidez
    geometría, batch `update`/`remove` que graban UN undo por gesto). El
    undo del gesto completo es un solo paso; sin "shift-click", sin menú
    ni hotkey esta ronda.

`swift build` limpio · `swift test` verde: **154** pruebas Swift Testing (22 suites) +
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

> Las mejoras y funciones futuras viven en `ROADMAP.md` (hoja de ruta viva);
> esta sección solo registra limitaciones conocidas de lo que está hecho.

- Texto: los bounds guardados siguen siendo aproximados (por diseño: anclan
  hit-test generoso y el filtro de pantalla, no métricas exactas de glifos).
- El autoguardado guarda solo lo dibujado (anotaciones); el undo/redo sigue
  siendo de sesión. Restaurar con otro layout de pantallas funciona por las
  coordenadas globales, pero las anotaciones pueden quedar fuera de vista.
- Lupa: el hosting del puntero refresca a la cadencia elegida (~3/~8 fps);
  las demás pantallas solo reciben snapshot en build (con espejo activo
  reciben el frame del puntero cada tick, también a esa cadencia).
- Grabación por ventana: el track se fija al arrancar pero el stream
  reescala el contenido y el burn-in sigue la geometría viva (una ventana
  que cambia de aspecto puede estirarse levemente — medido, no bandas).
  El rastro del cursor exige Accesibilidad (con/Acc) — sin ella, los
  efectos exigibles al puntero (lupa/anillo/hueco) no se queman ese frame.
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
