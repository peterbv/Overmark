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
  (burn-in de anotaciones), DMG firmado ad-hoc.
- 105 tests (17 suites Swift Testing) + 24 XCTest — verdes en cada cambio.

## 1. Funciones nuevas (mayor valor)

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 1 | **Persistencia de documentos de anotación** | Alta | **Hecho** | Autosave por documento + lista para retomar (pestaña Documentos). Undo/limpiar/borrado por clic derecho intactos. |
| 2 | **Pizarra dedicada** | Alta | Propuesto | Pantalla blanca completa para anotar sin contenido debajo, además del overlay sobre apps. |
| 3 | **Lupa configurable** | Media | Propuesto | Limitada: ~3 fps y solo la pantalla del cursor (pantalla extra queda con snapshot de entrada). Ajustar tamaño, zoom, fps; opción de espejo en segunda pantalla. |
| 4 | **Grabación con efectos de cursor incrustados** | Media | Propuesto | La grabación por ventana quema las anotaciones pero no los efectos dedicados (anillo/ripples/lupa); hacer que vayan dentro del video. |

## 2. Mejoras rápidas (una sesión cada una)

| # | Idea | Prioridad | Estado | Notas |
|---|---|---|---|---|
| 5 | **Botón lápiz en la barra** | Alta | **Hecho** | Botón `pencil.tip` junto a pausa: bloquea el lápiz (cada clic dibuja, sin ⌥) / vuelve a requerir ⌥. El chip "captura todo" también alterna con un tap. |
| 6 | **Tecla modificadora configurable** | Media | Propuesto | Elegir ⌥ / ⌃ / ⌘ en vez del ⌥ fijo. |
| 7 | **Auto-borrado para formas y texto** | Media | Propuesto | El desvanecimiento hoy solo aplica a trazos dibujados; extender a rectángulos, elipses, flechas y números. |

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
