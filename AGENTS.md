# AGENTS.md — Overmark

Guía para agentes de código (y humanos) que trabajen en este repo.

Overmark es una app de anotación en pantalla para macOS (barra de menú,
modo accesorio), Swift Package (swift-tools 6.0, macOS 14+), sin sandbox.

## Documentos de verdad

| Archivo | Contenido |
|---|---|
| `PROJECT_STATUS.md` | Estado **real** del proyecto: qué funciona, historia de fixes por ronda, métricas. Es la fuente de verdad del presente. |
| `ROADMAP.md` | El futuro: backlog numerado, banco de ideas y registro de decisiones. |
| `Support/DISTRIBUTION.md` | Firma Developer ID + notarización del DMG. |

**Regla de oro**: toda ronda de cambios termina con commit temático **más**
actualización de `PROJECT_STATUS.md` (nueva entrada en la historia de
fixes) y `ROADMAP.md` (registro de decisión) si la ronda tocó el roadmap.

## Construir y verificar

```bash
swift build && swift test     # build + suite completa
bash Scripts/build-app.sh     # → build/Overmark.app + build/Overmark.dmg
```

- Métricas esperadas al cerrar una ronda: **171** pruebas Swift Testing
  (25 suites) + **24** XCTest del grabador. Si una ronda toca lógica de
  Core, esperan tests nuevos; si es ronda UI, la convención previa es no
  sumar (AppKit/ScreenCaptureKit no corren headless).
- **Sonda headless**: `OVERMARK_PROBE=1` sobre el binario ejecuta la
  secuencia completa (39 pasos) y sale limpia. Es el reemplazo de "probar
  a mano" en CI/agentes; imprime líneas `[PROBE] ...` (tamaños de
  barra, estado de permisos TCC, etc.).
- Firma ad-hoc: cada rebuild puede pedir re-conceder permisos TCC
  (Grabación de pantalla/Accesibilidad) — es esperado, no un bug.

## Estructura mental del código

- **OvermarkCore**: modelo puro y testeado (documento de anotaciones,
  preferencias, archivo de sesión `SessionArchive`, `ScreenChoice`,
  `ToolbarDock`). CG-puro — nada de AppKit acá.
- **OvermarkCapture**: captura de pantalla (`ScreenCaptureService`),
  renderers CG-puros (`AnnotationRenderer`, `CursorEffectRenderer`,
  `GraphicsExport`), `PrimaryScreen`.
- **OvermarkRecorder**: grabación `SCStream → AVAssetWriter` con burn-in
  por frame (anotaciones + efectos de cursor).
- **App (host)**: `AppDelegate` con `@main` manual (`static func main()`),
  ventanas propias en NSHostingView (barra, settings, onboarding). El
  bundle **no declara escenas SwiftUI** — no re-introducirlas.
- Repaint de overlays: por **dirty-rects** (unión de región antes/después);
  los didSet estructurales son los únicos full-repaint.

## Convenciones que no se negocian

- Strings de UI en `L10n.swift` (es/en) — nada de texto hardcodeado.
- Preferencias persistidas con decode **tolerante** (`decodeIfPresent`):
  un campo nuevo no debe descartar el blob viejo del usuario.
- Quit/grabación: salir (ESC, ⌘Q, logout) finaliza siempre el `.mov`.
- Errores de disco no se comen: suben al canal de errores de la barra.
- Commits estilo repo: `feat:/fix:/perf:/refactor:/docs:` en inglés,
  cuerpo opcional; una ronda = un commit (o doc-commit aparte si aplica).
