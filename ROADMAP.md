# ROADMAP — Overmark

> Hoja de ruta viva. Última actualización: 22 oct 2026.
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
  spotlight, lupa, zoom — configurables y persistidos.
- Colores: paleta integrada + favoritos del usuario (máx. 8) + panel de
  selección; gradiente por anotación; relleno por anotación.
- Preferencias persistidas (`PreferencesStore`) entre lanzamientos.
- Modos de interacción: **⌥-para-dibujar** (passthrough a nivel window
  server), **Pausa** (⌘⇧S), **captura total** — todos visibles por chips en
  la barra; recuperación automática cuando Accesibilidad vuelve.
- Capturas multi-monitor (copiar / guardar), grabación de ventana en vivo
  (burn-in de anotaciones + efectos de cursor), DMG firmado ad-hoc.
- Pizarra dedicada como estado del overlay (sesión activa, ☑ en menú y
  barra, ⌘⇧B) con tono blanco/negro persistido; pausa pliega el lienzo
  y las capturas componen el relleno del tablero.
- 129 tests (21 suites Swift Testing) + 24 XCTest — verdes en cada cambio.

## 1. Funciones nuevas (mayor valor)

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 1 | **Persistencia de documentos de anotación** | Alta | **Hecho** | Autosave por documento + lista para retomar (pestaña Documentos). Undo/limpiar/borrado por clic derecho intactos. |
| 2 | **Pizarra dedicada** | Alta | **Hecho** | Estado del overlay dentro de la sesión (no un modo nuevo): cubre las pantallas del scope con lienzo blanco o negro; botón en barra, ☑ en menú, ⌘⇧B. Pausa muestra el desktop con la pizarra plegada. Copiar/guardar composite el relleno. |
| 3 | **Lupa configurable** | Media | Propuesto | Limitada: ~3 fps y solo la pantalla del cursor (pantalla extra queda con snapshot de entrada). Ajustar tamaño, zoom, fps; opción de espejo en segunda pantalla. |
| 4 | **Grabación con efectos de cursor incrustados** | Media | **Hecho** | Los efectos (anillo, spotlight, lupa, ripples) se queman por frame en la grabación de ventana con la misma matriz de anotaciones; la lupa muestra contenido limpio de la ventana, sin anotaciones. La grabación de pantalla ya los mostraba (sus ventanas están en la cinta). |

## 2. Mejoras rápidas (una sesión cada una)

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 5 | **Botón lápiz en la barra** | Alta | **Hecho** | Botón `pencil.tip` junto a pausa: bloquea el lápiz (cada clic dibuja, sin ⌥) / vuelve a requerir ⌥. El chip "captura todo" también alterna con un tap. |
| 6 | **Tecla modificadora configurable** | Media | **Hecho** | Preferencias → Herramientas: ⌥/⌃/⌘ como "tecla de dibujo" (persistida en `Overmark.drawingModifier`), aplicada en caliente — el tap de flagsChanged retargetea el bit, los lienzos re-chequean la máscara del evento vivo y el chip muestra el símbolo real. |
| 7 | **Auto-borrado para formas y texto** | Media | Hecho | Hallazgo: formas y texto ya se desvanecían (la nota original era imprecisa). Cambio real: los números de paso entran al temporizador y el contador se vuelve monótono (piso que solo `limpiar`/restaurar reinician) para no reutilizar números ya mostrados. |

## 3. Infraestructura / calidad

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 8 | **Firma Developer ID real** | Alta (si distribuimos) | Propuesto | Elimina el re-grant de permisos TCC en cada compilación (dolor conocido: cdhash ad-hoc cambia → Accesibilidad/Captura se vuelven a pedir). Bloqueante para distribuir el DMG. |
| 9 | **Limpiar Settings residual de SwiftUI** | Baja | Propuesto | La escena `Settings` quedó muerta (se usa ventana propia); código vivo pero residual. |
| 10 | **Checklist GitHub** | Media (al publicar) | Propuesto | CI (Actions en runner macOS), releases con DMG verificable (`codesign --verify --deep`), README bilingüe con GIFs, LICENSE (¿MIT?), `git remote` + proteger main, Sparkle si hay usuarios reales. |

## 4. Banco de ideas (sin compromiso, a evaluar)

- **Congelar pantalla**: pausa en frame estático para anotar encima sin que
  el fondo se mueva.
- **Puntero láser**: seguimiento del cursor con rastro luminoso (combo
  natural con la infraestructura actual de efectos).
- **Mover/recolorear anotaciones existentes**: selección por marquee para
  arrastrar, cambiar color o borrar lo ya dibujado (hoy: borrar clic
  derecho y undo).
- **Exportar**: PNG/PDF de la sesión actual; GIF corto del overlay animado.
- **Sellos/símbolos**: stamps de check, ✗, flechas curvas, emojis.
- **Temporizador en pantalla**: cuenta regresiva visible durante presentaciones.
- **Borrador por arrastre**: borrar trazos con un gesto continuo.
- **Extensión de favoritos**: favoritos de gradiente y de combinaciones
  color+grosor (hoy solo color sólido).
- **i18n**: más idiomas aparte de es/en (los strings ya están centralizados
  en `L10n.swift`).
- **Multiventana de grabación**: grabar dos ventanas en paralelo.

## Registro de decisiones

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
