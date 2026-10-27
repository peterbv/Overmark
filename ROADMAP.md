# ROADMAP — Overmark

> Hoja de ruta viva. Última actualización: 23 oct 2026.
>
> El estado y la arquitectura del código viven en `PROJECT_STATUS.md`; este
> documento registra **futuro**: qué agregar, qué mejorar y por dónde seguir.

## Qué ya está hecho (para no re-pensarlo)

- Herramientas: lápiz, marcador, flecha, rectángulo, elipse, texto
  (edición in-situ), números de pasos — con color, grosor y trazo degradado.
- **Persistencia de documentos**: autoguardado con debounce + flush al
  salir/terminar; pestaña Documentos para guardar con nombre, restaurar o
  eliminar (archivos JSON atómicos por `SessionArchive`, tolerantes a
  corrupción).
- Auto-borrado de trazos dibujados con tiempo configurable.
- Efectos de cursor: anillo (círculo/squircle/rombo), ripples de clic,
  spotlight, lupa (tamaño 80–420, refresco normal/fluida, espejo en otras
  pantallas), zoom y puntero láser (rastro luminoso) — configurables
  y persistidos.
- Colores: paleta integrada + favoritos del usuario (máx. 8) + panel de
  selección; gradiente por anotación; relleno por anotación.
- Preferencias persistidas (`PreferencesStore`) entre lanzamientos.
- Modos de interacción: **⌥-para-dibujar** (passthrough a nivel window
  server), **Pausa** (⌘⇧S), **captura total** — todos visibles por chips en
  la barra; recuperación automática cuando Accesibilidad vuelve.
- Capturas multi-monitor (copiar / guardar), grabación de ventana en vivo
  (burn-in de anotaciones + efectos de cursor), DMG firmado ad-hoc.
- Exportación desde el menú: la sesión actual (con anotaciones, pizarra y
  freeze compuestos) sale como PNG o PDF de una página.
- Pizarra dedicada como estado del overlay (sesión activa, ☑ en menú y
  barra, ⌘⇧B) con tono blanco/negro persistido; pausa pliega el lienzo
  y las capturas componen el relleno del tablero.
- Congelar pantalla como estado del overlay (still de las pantallas del
  scope detrás de las anotaciones, ☑ en menú y barra, ⌘⇧P); excluyente
  con la pizarra, pausa pliega el still y las capturas lo componen.
- Selección de anotaciones (botón en la barra): marquee por intersección,
  arrastrar mueve con clamp a la pantalla, la paleta recolorea, la basura
  borra lo seleccionado; un solo undo por gesto.
- Barra flotante anclable (Settings → General): Arriba / Abajo / Izquierda /
  Derecha, persistido; la pestañita de recuperación se queda fija en el slot
  del dock y desplegar vuelve exactamente a él (arrastre libre, sin snap).
- Barra flotante vertical: en los docks laterales la misma barra se arma en
  dos columnas (herramientas/control | efectos/estilo con paleta en grilla),
  reconstruida en vivo al alternar la orientación del dock.
- Barra minimizada por defecto: herramientas + undo/rehacer/basura + pausa +
  Listo en una fila (o columna); el chevron re-fluye a la barra completa y
  de vuelta en un clic.
- 163 tests (24 suites Swift Testing, incluida "Toolbar dock") + 24
  XCTest — verdes en cada cambio.

## 1. Funciones nuevas (mayor valor)

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 1 | **Persistencia de documentos de anotación** | Alta | **Hecho** | Autosave por documento + lista para retomar (pestaña Documentos). Undo/limpiar/borrado por clic derecho intactos. |
| 2 | **Pizarra dedicada** | Alta | **Hecho** | Estado del overlay dentro de la sesión (no un modo nuevo): cubre las pantallas del scope con lienzo blanco o negro; botón en barra, ☑ en menú, ⌘⇧B. Pausa muestra el desktop con la pizarra plegada. Copiar/guardar composite el relleno. |
| 3 | **Lupa configurable** | Media | **Hecho** | Tamaño de lente (80–420 pt), tasa de refresco (normal ~3 fps / fluida ~8 fps, aplicada al siguiente tick) y espejo: la lupa se replica en las otras pantallas al punto proporcional del puntero; apagarla reconstruye y devuelve a cada pantalla su snapshot propio. El factor y la forma ya eran configurables. |
| 4 | **Grabación con efectos de cursor incrustados** | Media | **Hecho** | Los efectos (anillo, spotlight, lupa, ripples, láser) se queman por frame en la grabación de ventana con la misma matriz de anotaciones; la lupa muestra contenido limpio de la ventana, sin anotaciones. La grabación de pantalla ya los mostraba (sus ventanas están en la cinta). |
| 11 | **Puntero láser** | Alta | **Hecho** | Migrado del banco de ideas. Punto brillante + rastro que se apaga en ~0,7 s; toggle `cursorarrow.rays` en la barra y en Settings → Cursor (color y tamaño 2–14 pt). Quemado en la grabación de ventana por el mismo camino que el resto de los efectos. Codificación resiliente: el decode de `CursorEffects` ya no descarta el blob viejo cuando aparecen campos nuevos. |
| 12 | **Congelar pantalla** | Media | **Hecho** | Migrado del banco de ideas. Estado del overlay (hermano de la pizarra): captura una vez cada pantalla del scope (sin ventanas propias) y las canvases pintan ese still detrás de las anotaciones — el fondo queda quieto mientras las apps de abajo siguen corriendo. Botón `snowflake` en la barra, ☑ en menú, ⌘⇧P. Excluyente con la pizarra en ambos sentidos; pausa pliega el still; capturas componen el frame congelado; salir de la sesión lo suelta. |
| 13 | **Mover y recolorear anotaciones (marquee)** | Media | **Hecho** | Migrado del banco de ideas. Botón de selección en la barra: marquee por intersección de límites; arrastrar una selección la mueve con clamp a la pantalla; la paleta recolorea la selección (color sólido, limpia gradiente); la basura borra lo seleccionado (si no hay selección limpia todo). Un solo undo por gesto (batch `update`/`remove(id:)`). Pasa a dibujar (elegir herramienta) limpia la selección. |
| 14 | **Exportar PNG/PDF de la sesión** | Media | **Hecho** | Migrado del banco de ideas. Ítems "Export PNG…/Export PDF…" en el menú (al lado de Save Screenshot…): el compositor ya produce la imagen final (anotaciones + pizarra + freeze) y `GraphicsExport` (CG-puro, testeado) la envuelve en PNG (ImageIO) o PDF de una página (CGPDFContext, página blanca para que los visores no pinten alpha como negro). NSSavePanel con nombre `Overmark-fecha`; sin hotkeys esta ronda. GIF animado sigue en el banco por peso (SCStream→GIF). |
| 15 | **Dock de la barra flotante** | Alta (pedido del owner) | **Hecho** | Settings → General: anclar la barra Arriba / Abajo / Izquierda / Derecha (persistido, aplicado en vivo vía `reapplyDock`). La pestañita de recuperación se ancla SIEMPRE al slot del dock (borde de pantalla, 48×12) — deja de derivar con cada plegado (causa raíz: pegarla al borde de la barra, que cambia con el arrastre). Desplegar vuelve exactamente al dock; el arrastre quedó libre (sin snap a esquinas) y el dock es el único imán. Orientación vertical de dos columnas hecha en #16. |
| 16 | **Barra flotante vertical** | Alta (pedido del owner) | **Hecho** | En los docks laterales la barra se arma en dos columnas (~240×700): herramientas + undo/trash + pausa/ayuda/preferencias/pin + Listo en la primera; efectos, alcance, grabación, lápiz/pizarra/congelar/marquee, paleta en grilla, slider vertical y chips en la segunda. `reapplyDock` reconstruye el contenido al alternar orientación; el handle pasa a una tira vertical en el borde interno; el drag libre y el re-use de estilos se mantienen. |
| 17 | **Modo minimizado de la barra** | Media (idea del owner) | **Hecho** | La barra arranca minimizada: herramientas + undo/rehacer/basura + pausa + Listo en una fila (580×60) o una columna (84×540) según el dock. El mismo chevron que comparte la barra completa la re-fluye y el panel se re-ancla al dock con el tamaño nuevo. Sin preferencia: es estado del controller (arranca minimizado en cada sesión). |

## 2. Mejoras rápidas (una sesión cada una)

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 5 | **Botón lápiz en la barra** | Alta | **Hecho** | Botón `pencil.tip` junto a pausa: bloquea el lápiz (cada clic dibuja, sin ⌥) / vuelve a requerir ⌥. El chip "captura todo" también alterna con un tap. |
| 6 | **Tecla modificadora configurable** | Media | **Hecho** | Preferencias → Herramientas: ⌥/⌃/⌘ como "tecla de dibujo" (persistida en `Overmark.drawingModifier`), aplicada en caliente — el tap de flagsChanged retargetea el bit, los lienzos re-chequean la máscara del evento vivo y el chip muestra el símbolo real. |
| 7 | **Auto-borrado para formas y texto** | Media | Hecho | Hallazgo: formas y texto ya se desvanecían (la nota original era imprecisa). Cambio real: los números de paso entran al temporizador y el contador se vuelve monótono (piso que solo `limpiar`/restaurar reinician) para no reutilizar números ya mostrados. |

## 3. Infraestructura / calidad

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 8 | **Firma Developer ID real** | Alta (si distribuimos) | **Hecho (infra)** | Pipeline listo con cert ausente: `build-app.sh` autodetecta el primer "Developer ID Application" del llavero (_OVERRIDE ad-hoc con `OVERMARK_SIGN_IDENTITY="-"`), notarización opcional (`--notary-profile` / `OVERMARK_NOTARY_PROFILE` → `notarytool submit --wait` + `stapler staple` al DMG) y guía completa en `Support/DISTRIBUTION.md`. El requisito ad-hoc estable (`designated => identifier`, keys TCC) sigue para builds sin cert. Falta únicamente comprar el Developer ID. |
| 9 | **Limpiar Settings residual de SwiftUI** | Baja | Propuesto | La escena `Settings` quedó muerta (se usa ventana propia); código vivo pero residual. |
| 10 | **Checklist GitHub** | Media (al publicar) | Propuesto | CI (Actions en runner macOS), releases con DMG verificable (`codesign --verify --deep`), README bilingüe con GIFs, LICENSE (¿MIT?), `git remote` + proteger main, Sparkle si hay usuarios reales. |

## 4. Banco de ideas (sin compromiso, a evaluar)

- **Exportar GIF**: GIF corto del overlay animado (PNG/PDF ya son Hecho; el
  GIF queda por peso técnico: convertir el stream a GIF eficientemente).
- **Sellos/símbolos**: stamps de check, ✗, flechas curvas, emojis.
- **Temporizador en pantalla**: cuenta regresiva visible durante presentaciones.
- **Borrador por arrastre**: borrar trazos con un gesto continuo.
- **Extensión de favoritos**: favoritos de gradiente y de combinaciones
  color+grosor (hoy solo color sólido).
- **i18n**: más idiomas aparte de es/en (los strings ya están centralizados
  en `L10n.swift`).
- **Multiventana de grabación**: grabar dos ventanas en paralelo.

## Registro de decisiones

- **26 oct 2026** — **Ronda 33: robustez tras revisión de código** (no sale
  del banco de ideas; el owner eligió los 4 prioritarios del informe).
  (1) **Taps a prueba de stall**: macOS puede desactivar un event tap si
  su callback demora; los callbacks de cursor y gate ⌥ re-arman el tap
  al recibir `tapDisabledByTimeout`/`tapDisabledByUserInput` (`tapEnable`
  por la referencia guardada — el proxy del callback no es el mach
  port); `CursorTracker` además baja de `.defaultTap` a `listenOnly` por
  ser solo observador. (2) **Editor de texto sin ciclo de retención**:
  `onCancel`/`onCommit` sujetan la ventana débil (`[weak window]`) —
  window → contentView → closures → window filtraba un `NSWindow` por
  cada edición. (3) **Quits completos**: ⌘Q/logout/AppleScript pasan por
  `applicationShouldTerminate` → `prepareForTermination`, que espera la
  finalización de la grabación antes de responder; y si el `start` de la
  grabadora falla a mitad (permiso de micro, ventana que muere),
  `discardPartialRun` detiene los streams, cierra el writer y **borra el
  `.mov` vacío** — antes quedaban stream vivo + archivo huérfano. El
  "never left half-written" del README ahora es cierto también saliendo
  con ⌘Q. (4) **Burn-in copy-first**: el quemado de anotaciones en la
  grabación de ventana dibuja en una copia propia del buffer y no dentro
  del buffer del pool de SCStream (riesgo de tearing bajo backpressure);
  sin anotaciones ni efectos el frame sigue tal cual (zero-copy).

- **25 oct 2026** — **#8 hecho (infra): firma Developer ID + notarización
  listas, a la espera del certificado** (el llavero del owner aún no tiene
  identidades; decisión: dejar el pipeline terminado y documentado). Piezas:
  (1) `build-app.sh` autodetecta el primer "Developer ID Application" del
  llavero y firma con él; ad-hoc queda como fallback (y el env
  `OVERMARK_SIGN_IDENTITY="-"` lo fuerza, útil en CI). (2) `--notary-profile` / env
  `OVERMARK_NOTARY_PROFILE` encadenan `notarytool submit --wait` +
  `stapler staple` sobre el DMG ya firmado y verificado (release con
  `--options runtime --timestamp`). (3) `Support/DISTRIBUTION.md`: guía
  bilingüe — compra del cert, `store-credentials`, flujo completo y
  verificación (`spctl`/`stapler validate`). (4) El requisito ad-hoc
  estable (`designated => identifier "com.overmark.app"`) queda intocado
  para builds sin firma — el fix del re-grant TCC sigue salvando el modo
  local. Verificado end-to-end ad-hoc: firma válida, DR satisfecho, DMG
  emitido.

- **25 oct 2026** — **#17 hecho: modo minimizado de la barra** (idea del
  owner: "un modo minimizado con las funciones más útiles y poder expandir
  para mostrar todas"). Piezas: (1) la barra arranca **minimizada** —
  herramientas + undo/rehacer/basura + pausa + chevron + Listo en una
  fila (o una columna en docks laterales). (2) El mismo chevron en la
  barra completa la devuelve al compacto; el panel re-ancla al dock con el
  tamaño nuevo (`toggleMinimized()` en el controller, expuesto como
  `toggleToolbarMinimized()` — predeterminado true, sin preferencia). (3)
  `compactBarSize` (580×60) / `compactVerticalBarSize` (84×540) alimentan
  `dockRect`. (4) Ayudas es/en ("Show only the essentials" / "Show all
  controls" — "Mostrar solo lo esencial / todas las funciones").
  (Cierre del pedido de la barra junto a #15/#16 del 23 oct.)

- **23 oct 2026** — **#15 hecho: dock de la barra flotante** (pedido del
  owner: "la pestañita sigue moviéndose de lugar cada vez que aparece; debe
  quedarse quieta, y la barra debe poder ir horizontal o vertical en los
  lados o arriba o abajo"). Piezas: (1) `ToolbarDock` (top/bottom/leading/
  trailing) en Core + preferencia `Overmark.toolbarDock` (default Arriba).
  (2) El controller calcula `dockRect` y `tabSlot` para las cuatro
  posiciones: la pestañita de recuperación se ancla al **slot del dock** en
  el borde de la pantalla — la causa de la deriva era anclarla al borde de
  la *barra*, que cambia con cada arrastre). (3) `showExpanded` vuelve al
  dock exacto y `reapplyDock()` aplica el cambio de anclaje en vivo
  (pestañita incluida). (4) El arrastre quedó libre: se eliminó el snap a
  esquinas (el dock es el único imán). La orientación vertical de dos
  columnas se hizo en #16.

- **23 oct 2026** — **#16 hecho: barra flotante vertical** (segunda parte del
  pedido del owner: "modo horizontal y vertical para acomodarlo en los
  lados"). Piezas: (1) `verticalBarSize` (240×700) + `contentIsVertical` en
  el controller — `dockRect` usa el tamaño según `ToolbarDock.isHorizontal`.
  (2) `AnnotationToolbarView.isVertical` reparte en dos columnas
  (herramientas/control | efectos/estilo) reutilizando los mismos botones y
  helps; `ColorPalette` ganó `layout` (`.grid` con 3 columnas para la
  barra vertical, `.row` intacto en Settings). (3) Slider vertical via
  rotation. (4) `reapplyDock()` reconstruye el contentView al alternar
  orientación en vivo. (5) `makeExpandedContent` perdió el param vestigial
  `handleFrame` y el handle se convierte en tira vertical (12×80) en el
  borde interno con dock lateral.

- **23 oct 2026** — **#14 hecho: exportar PNG/PDF de la sesión.** Piezas: (1)
  `GraphicsExport` en Capture, CG-puro y testeado — `pngData` (ImageIO
  con destino en memoria) y `pdfData` (CGPDFContext sobre `CGDataConsumer`,
  pinta primero la página de blanco porque los visores de PDF muestran el
  alpha como negro, y dibuja la imagen). (2) El compositor ya entrega la
  imagen final con todo compuesto — el export reusa `captureDesktopImage()`
  sin duplicar nada. (3) Coordinator: `exportPNG()/exportPDF()` con
  NSSavePanel (`UTType.png/.pdf`, nombre `Overmark-fecha`, escritura
  atómica) y errores a `lastError`. (4) Menú: ítems junto a Save
  Screenshot…; sin hotkeys (paridad con esa acción). Tests: firma y
  round-trip de PNG, header `%PDF` y una sola página vía PDFKit. El GIF
  animado del banco queda por evaluar por peso (SCStream→GIF).

- **23 oct 2026** — **#13 hecho: mover y recolorear anotaciones (marquee).**
  Estado de sesión del overlay (mismo patrón que pizarra/freeze): el botón
  de selección en la barra activa `isSelectionMode` y el canvas rutea
  los gestos por su cuenta (marquee por intersección de límites, arrastre
  de selección con clamp para no salir de la pantalla, sin dibujar). El
  recolor sale barato: la paleta ya persiste en settings, así que el
  `didSet` aplica `with(color:)` a la selección (color sólido — el
  gradiente se limpia). Borrar es la basura existente que decide entre
  limpiar todo y borrar lo seleccionado. Undo es un solo paso por gesto:
  batch mutators nuevos en `AnnotationDocument`
  (`update(_ recordHistory:)` y `remove(id:recordHistory:)`). Sin modos
  `AppMode`, sin columna de menú ni hotkey (queda sugerido para después).

- **23 oct 2026** — **Fix: la barra anclada ya no se fuga del escritorio**
  (`2c050fc`). El colapso pegaba la pestaña a los bordes de la barra, pero
  la expansión crecía desde el *origen* de la pestaña con el clamp de
  arrastre (120 pt visibles) — cada ciclo empujaba la barra un ancho más
  afuera hasta que la pestaña misma caía fuera de alcance. Ahora la
  expansión invierte el colapso (esquina ancla → posición exacta
  previa), la pestaña se clampa íntegra dentro de las pantallas al
  plegarse y un clamp de visibilidad completa cubre el caso de displays
  rearrangiados mientras la barra estaba plegada.

- **23 oct 2026** — **#3 hecho: lupa configurable.** Tres piezas sobre la
  infraestructura existente. (1) `zoomSize` ya era persistido pero sin UI —
  slider 80–420 pt en Settings → Cursor. (2) La cadencia del loop de refresco
  estaba hardcodeada (320 ms): `LensRefreshRate {normal, responsive}` con
  intervalos 0,32/0,12 s, releído en cada tick para que el cambio aplique sin
  re-montar la tarea. (3) Espejo: `lensSourceScreen` en la vista (nil = lupa
  normal); el loop del cursor le pasa a las demás pantallas el screenshot de
  la pantalla del puntero y la vista mapea el punto por **posición
  proporcional** (`mirrorLensPlacement` en el renderer, CG-puro y testeado:
  identidad en la misma pantalla, mapeo cruzado por tamaños distintos). Al
  apagar el espejo se reconstruyen las ventanas para que cada pantalla
  recupere su snapshot de build — el in-place habría dejado contenido ajeno
  con un mapping extranjero. El toggle solo aparece con >1 pantalla.

- **23 oct 2026** — **Congelar pantalla hecho** (desde el banco de ideas).
  Encaje elegido: **estado del overlay hermano de la pizarra**, no un modo
  nuevo — `backdropImage` en el canvas (no toca `AnnotationTool`, cuyo
  `blur/spotlight/laserPointer` dormido recuerda que las herramientas
  "modeladas por futuro" no son el camino), dibujado después del relleno
  del tablero y antes del renderer: tabla `context.draw(image, in:
  bounds)` sobre el contexto y-up (igual que el resto del repo dibuja
  imágenes CG: upright sin flip). El coordinator captura cada pantalla del
  scope UNA vez con el `ScreenCaptureService` ya usado por capturas y lupa
  (excluye ventanas propias) y guarda el diccionario per-display: overlay
  y compositor comparten los frames. Excluyente con la pizarra en ambos
  sentidos (una pantalla no es lienzo y still a la vez); pausa pliega el
  still por `setFreezeVisible` al lado de `setBoardVisible`; las capturas
  copian/guardan compositando el frame congelado (`frozen:`/`frozenFill:`
  en el compositor, con precedencia sobre `backdrop:`). Salir de la sesión
  y quitar la pieza resets. En el probe las capturas quedan honestas sobre
  el grant TCC fresco del binario (`[PROBE] freeze: active=...`): sin
  re-grant, `SCShareableContent` no responde y el still no se activa — el
  canvas/compositor/passthrough quedan verificados por tests de pixel y
  por el mismo camino de pizarra. Hotkey **⌘⇧P**.

- **23 oct 2026** — **Puntero láser hecho** (desde el banco de ideas). La
  `AnnotationTool.laserPointer` que existía dormida en el enum quedó
  descartada como encaje: un láser es transitorio y no pertenece al
  documento de anotaciones — sobre si entra más adelante como sello
  persistente. En su lugar: **efecto de cursor** (`CursorEffects` +
  `isLaserEnabled/laserColor/laserRadius`), reusando la infraestructura
  completa de la ronda #4: las ventanas de efecto lo dibujan con
  `CursorEffectRenderer.drawLaserDot/drawLaserTrail` (halo + núcleo + fleca
  blanca; la cola se apaga en ~0,7 s con un ticker de 30 fps mientras el
  cursor está quieto) y la grabación por ventana lo quema con la misma
  matriz, orden z: dim → lupa → anillo → láser → ripples. El box del
  recorder muestrea la cola en cada `updateCursor` (prune 0,75 s, tope 64).
  Cambio estructural de regalo: `CursorEffects` pasó de Codable sintético a
  `init(from:)` tolerante (`decodeIfPresent` en todos los campos) — las
  preferencias guardadas ya no se descartan cuando se agrega un campo
  (el mismo dolor que motivó la preferencia separada en #6). Toggle en la
  barra (`cursorarrow.rays`, 4º efecto) y en Settings → Cursor.

- **22 oct 2026** — **#4 hecho: grabación de ventana quema los efectos de
  cursor.** Hallazgo al reabrir el ítem: la grabación de pantalla ya
  incluye los efectos (sus ventanas de efecto están en la cinta; solo el
  chrome se excluye), así que el delta real era la grabación por ventana.
  Nueva pieza Core (`CursorEffectFrame`: settings + puntero + clics en un
  snapshot thread-safe, espejo del box de anotaciones) y un renderer
  CG-puro en Capture (`CursorEffectRenderer`) donde VIVE el dibujo de los
  efectos: la ventana on-screen delega en él y el recorder lo llama con la
  misma matriz que anotaciones, en espacio AppKit — el video muestra los
  efectos exactamente donde flotan. Lupa: se quema un snapshot *limpio*
  del buffer (antes de pintar anotaciones), igual que la lupa en pantalla
  excluye las ventanas overlay de su captura. El spotlight quema con clip
  even-odd (el blend `.clear` de la ventana transparente habría ennegrecido
  el buffer opaco). Ripples solo si hay clics registrados; el cursor exige
  Accesibilidad, igual que en pantalla. Sin settings ni UI nueva.

- **22 oct 2026** — **#6 hecho: tecla de dibujo configurable.** El ⌥ fijo
  deja de estar hardcodeado: `DrawingModifier` (⌥/⌃/⌘, nuevo enum Core con
  símbolo) persiste como preferencia separada (`Overmark.drawingModifier`)
  para no perturbar el blob codificado de `ToolSettings` (un campo nuevo
  habría descartado las preferencias del usuario por decode fallido). El
  `OptionKeyMonitor` pasa a ser `ModifierKeyMonitor` con `setMask`
  (retarget del bit rastreado sin remontar el tap); los lienzos re-chequean
  `NSApp.currentEvent` contra la máscara elegida (`requiredModifier`). El
  push en caliente: `drawingModifier.didSet` → `overlay.setDrawingModifier`
  (+ push manual en el primer build, porque el `didSet` no corre en init).
  El chip de la barra muestra el símbolo real (⌘ queda disponible con la
  nota de que choca con los atajos de menú del app anfitrión mientras se
  mantiene. Probe verifica la conmutación en vivo.

- **22 oct 2026** — **#7 hecho: auto-borrado completo.** Hallazgo al
  implementar: formas y texto **ya** se desvanecían (la nota original del
  ítem era imprecisa — `isFadeable` cubre todo lo que produce anotaciones).
  El cambio real: los **números de paso entran al temporizador** y el
  contador pasa a ser **monótono** (`stepNumberFloor` en el coordinator,
  elevado por cada sello que se desvanece; solo limpiar la pizarra o
  restaurar un documento reinicia la numeración) para que un número visto
  jamás se reemita tras el fade. Caso sutil cubierto: cuando se desvanece
  el sello de mayor número mientras quedan otros presentes, el piso evita
  que el siguiente sello repita un número ya mostrado.
- **22 oct 2026** — **#2 hecho: pizarra dedicada.** Decisión de encaje: no es
  un `AppMode` nuevo sino **estado del overlay** — el canvas pinta el
  tablero opaco (blanco/negro, `BoardStyle` persistido en
  `PreferencesStore`) y reclama cada clic (sin gate ⌥; `hitTest` corto) con
  el panel reutilizado. Botón `rectangle.inset.filled` en la barra, ítem con
  checkmark en el menú, atajo ⌘⇧B. Pausa pliega el lienzo (desktop usable
  sin apagar la pizarra); salir la apaga para la próxima sesión. Las
  capturas excluyen ventanas propias, así que el compositor añade el
  relleno del tablero (`boardFill` → `backdrop`): copiar/guardar muestran
  lo que vio el público. Probe extiende su secuencia con pizarra on/tone
  switch/pause/resume.
- **22 oct 2026** — **#5 hecho: botón lápiz de bloqueo.** `EffectButton`
  `pencil.tip` junto a pausa: tintado = lápiz bloqueado (`holdOptionToDraw`
  en `false`, cada clic dibuja sin mantener ⌥); apagado = modo ⌥-dibujar.
  Reusa el flag ya persistido de Tools (el `didSet` de settings re-aplica el
  overlay en vivo) — sin lógica nueva ni tests extra. El chip "captura todo"
  también alterna en el tap: vuelve a requerir ⌥ en vez de abrir Settings.
- **22 oct 2026** — **#1 hecho: persistencia de documentos.** Nuevo
  `SessionArchive` en el núcleo (`SessionSnapshot` v1 = anotaciones + layout
  de pantallas + fecha; directorio `Application Support/Overmark/Documents`)
  con autosave.json dedicado y documentos con nombre; el coordinator lo
  restaura al arrancar, autoguarda con debounce de 0,6 s y flushea al salir
  del modo o terminar la app. Preferencias gana una pestaña **Documentos**
  (guardar con nombre vía diálogo, lista con restaurar/eliminar). El undo
  sigue siendo de sesión — guardado y reabrir re-crea el documento sin
  historial. Validado end-to-end inyectando un autosave sintético y
  arrancando el probe (restaura y re-persiste). Test suite en 105 + 24.
- **22 oct 2026** — Se crea el documento tras la ronda de pulido de
  interacción (`92e956a` passthrough auto-recuperable, `5946ea2` chip
  "captura todo" visible, `2006026` icono de óvalo). Prioridad sugerida en
  voz del owner: #1 persistencia de documentos para uso propio; #8 firma
  real como bloqueante si se distribuye.
