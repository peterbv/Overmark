import Foundation

/// The languages in which Presentify talks to the user.
///
/// The app's copy is authored in English; `tr(_:)` maps each string to its
/// Spanish twin when Spanish is selected. Every user-facing surface reads its
/// text through this helper — menus, toolbar, settings, onboarding, the text
/// editor and error messages — so one switch flips the whole app.
@MainActor
public enum L10n {
    public enum Language: String, CaseIterable, Identifiable {
        /// Follow the system's preferred language.
        case auto
        case english = "en"
        case spanish = "es"

        public var id: String { rawValue }
    }

    /// The language the user picked. `AppCoordinator` loads and persists it;
    /// every view re-renders because the coordinator is observable.
    static var selected: Language = resolve(.auto)

    /// The language `tr(_:)` produces right now.
    private static var effective: Language { resolve(selected) }

    /// Collapses the "automatic" choice against the system's preference.
    static func resolve(_ language: Language) -> Language {
        switch language {
        case .english, .spanish:
            return language
        case .auto:
            return Locale.preferredLanguages.first?.hasPrefix("es") == true
                ? .spanish
                : .english
        }
    }

    /// Translates `key` — the English copy — into the active language.
    ///
    /// Unknown keys fall through unchanged, so an untranslated string degrades
    /// to English instead of disappearing.
    public static func tr(_ key: String) -> String {
        guard effective == .spanish else { return key }
        return spanish[key] ?? key
    }

    /// The Spanish copy, keyed by the English string.
    private static let spanish: [String: String] = [
        // Menu bar.
        "Start Annotating": "Iniciar anotación",
        "Stop Annotating": "Terminar anotación",
        "Pause": "Pausar",
        "Resume": "Reanudar",
        "Record the presentation": "Grabar la presentación",
        "Stop Recording": "Detener la grabación",
        "Annotation screen": "Pantalla de anotación",
        "Undo": "Deshacer",
        "Redo": "Rehacer",
        "Copy Screenshot": "Copiar captura",
        "Save Screenshot…": "Guardar captura…",
        "Settings…": "Preferencias…",
        "Quit Presentify": "Salir de Presentify",

        // Toolbar.
        "Done": "Listo",
        "Finish annotating": "Terminar la anotación",
        "Stop recording": "Detener la grabación",
        "Recording in progress": "Grabando",
        "All screens": "Todas las pantallas",
        "Choose which screens the annotation overlay covers":
            "Elige qué pantallas cubre la capa de anotación",
        "⌥ draw": "⌥ dibujar",
        "capture mode": "modo de captura",
        "Drag here to move the toolbar": "Arrastrá acá para mover la barra",
        "Auto-hide": "Auto-ocultar",
        "Show the controls": "Mostrar los controles",
        "Keyboard shortcuts": "Atajos de teclado",
        "Enter / end the presentation": "Entrar / terminar la presentación",
        "ESC always ends the presentation": "ESC siempre termina la presentación",
        "The overlay captures every click until Accessibility is granted (System Settings → Privacy & security → Accessibility). Press here to open it.":
            "El overlay captura todos los clics hasta que concedas Accesibilidad (Ajustes del Sistema → Privacidad y seguridad → Accesibilidad). Toca aquí para abrirla.",
        "While this says \"⌥ draw\", only clicks with ⌥ (Option) held draw on the overlay; every other click reaches the app underneath.":
            "Con \"⌥ dibujar\" activo, solo los clics con ⌥ (Opción) mantenida dibujan sobre la capa; los demás clics van a la app que está debajo.",

        // Settings — tabs and tools.
        "General": "General",
        "Tools": "Herramientas",
        "Cursor": "Cursor",
        "Permissions": "Permisos",
        "Recording": "Grabación",
        "Recording target": "Objetivo de la grabación",
        "Full screen": "Pantalla completa",
        "A window": "Una ventana",
        "Recording window": "Ventana a grabar",
        "Refresh windows": "Actualizar ventanas",
        "The chosen window is recorded following it; the annotations are burned into the video.":
            "La ventana elegida se graba siguiéndola y las anotaciones quedan dibujadas dentro del video.",
        "Presentify records the whole display, annotations included live.":
            "Presentify graba la pantalla completa, con las anotaciones en vivo.",
        "Frame rate": "Cuadros por segundo",
        "Codec": "Códec",
        "Recording saved: %@": "Grabación guardada: %@",
        "Click to show the file in Finder": "Clic para mostrar el archivo en Finder",
        "Last recording": "Última grabación",
        "Show in Finder": "Mostrar en Finder",
        "Finishing the recording…": "Terminando la grabación…",
        "Record the microphone": "Grabar el micrófono",
        "While this is on, Presentify asks for the microphone permission and records its sound into the presentation video.":
            "Con esta opción, Presentify pide el permiso de micrófono y graba tu voz en el video de la presentación.",
        "Open Microphone settings": "Abrir Ajustes de Micrófono",
        "Save folder": "Carpeta de guardado",
        "Choose": "Elegir",
        "Use default": "Usar la predeterminada",
        "Presentify will save presentations here.": "Presentify guardará las presentaciones aquí.",
        "Recording screen": "Pantalla a grabar",
        "Main display": "Pantalla principal",
        "Not available": "no disponible",
        "The chosen recording screen is not available; recording the main display.":
            "La pantalla elegida para grabar no está disponible; grabando la pantalla principal.",
        "The chosen recording window is not available; recording the full screen.":
            "La ventana elegida para grabar no está disponible; grabando la pantalla completa.",
        "The chosen annotation screen is not available; annotating the main display.":
            "La pantalla elegida para anotar no está disponible; anotando la pantalla principal.",
        "Displays changed; the annotation overlay was rebuilt.":
            "Cambiaron las pantallas; la capa de anotación se reconstruyó.",
        "Language": "Idioma",
        "Automatic": "Automático",
        "Tool": "Herramienta",
        "Width": "Grosor",
        "Thin": "Fino",
        "Thick": "Grueso",
        "Fill shapes": "Rellenar figuras",
        "Draw with ⌥ held": "Dibujar manteniendo ⌥",
        "Colour": "Color",
        "Effects": "Efectos",
        "Pointer highlight": "Resaltar puntero",
        "Pointer highlight customization": "Personalización del resaltado del puntero",
        "Ring size": "Tamaño del aro",
        "Ring colour": "Color del aro",
        "Hole size": "Tamaño del agujero",
        "Dimming": "Atenuación",
        "Spotlight": "Foco de luz",
        "Zoom lens": "Lupa",
        "Zoom": "Zoom",
        "Magnification": "Aumento",
        "Shape": "Forma",
        "Grant": "Conceder",
        "Open System Settings": "Abrir Ajustes del Sistema",

        "On: clicks pass through to the app underneath and only clicks with ⌥ (Option) held draw on the overlay. Off: the overlay captures every click outside the menu bar strip.":
            "Activado: los clics atraviesan hasta la app de abajo y solo los clics con ⌥ (Opción) dibujan sobre la capa. Desactivado: la capa captura todos los clics fuera de la franja de la barra de menús.",
        "Hold ⌥ (Option) and draw to annotate. Plain clicks go to the app beneath the overlay.":
            "Mantén ⌥ (Opción) y dibuja para anotar. Los clics normales van a la app que está debajo de la capa.",
        "The overlay captures every click. Use the pause button on the toolbar to interact with other apps.":
            "La capa captura todos los clics. Usa el botón de pausa de la barra para interactuar con otras apps.",
        "Changes apply immediately to the menus, the toolbar and every window.":
            "Los cambios se aplican de inmediato en los menús, la barra y todas las ventanas.",

        // Tool names.
        "Pen": "Lápiz",
        "Line": "Línea",
        "Arrow": "Flecha",
        "Rectangle": "Rectángulo",
        "Ellipse": "Elipse",
        "Text": "Texto",
        "Spotlight tool": "Foco de luz",
        "Blur": "Desenfoque",
        "Highlighter": "Resaltador",
        "Step Number": "Número de paso",
        "Laser Pointer": "Puntero láser",

        // Zoom shapes.
        "Circle": "Círculo",
        "Squircle": "Cuadrado redondeado",

        // Permissions.
        "Screen Recording": "Grabación de pantalla",
        "Accessibility": "Accesibilidad",
        "Microphone": "Micrófono",
        "Presentify needs to see the screen so it can draw annotations on top of whatever you are showing.":
            "Presentify necesita ver la pantalla para dibujar anotaciones sobre lo que estés mostrando.",
        "Presentify needs this to track your pointer and notice keyboard shortcuts while you are in other apps.":
            "Presentify lo necesita para seguir tu puntero y detectar atajos de teclado mientras usas otras apps.",
        "Presentify needs your microphone to record its sound along with the presentation video.":
            "Presentify necesita tu micrófono para grabar el sonido junto con el video de la presentación.",
        "Granted": "Concedido",
        "Denied": "Denegado",
        "Not set up": "Sin configurar",
        "Grant Access": "Conceder acceso",
        "Open Settings": "Abrir Ajustes",

        // Onboarding.
        "Welcome to Presentify": "Te damos la bienvenida a Presentify",
        "Two permissions are needed to annotate your screen. You can change them later in System Settings.":
            "Se necesitan dos permisos para anotar tu pantalla. Podrás cambiarlos después en Ajustes del Sistema.",
        "Some features stay unavailable until every permission is granted.":
            "Algunas funciones no estarán disponibles hasta conceder todos los permisos.",
        "Continue": "Continuar",

        // Text annotation editor.
        "Add Text": "Añadir texto",
        "Type your text": "Escribe tu texto",
        "Size": "Tamaño",
        "Cancel": "Cancelar",
        "Add": "Añadir",

        // Text annotation window titles.
        "Presentify Settings": "Ajustes de Presentify",
        "Presentify Setup": "Configuración de Presentify",

        // Errors.
        "Presentify needs Screen Recording access to capture the screen.":
            "Presentify necesita acceso a Grabación de pantalla para capturar la pantalla.",
        "Presentify needs Screen Recording access to record.":
            "Presentify necesita acceso a Grabación de pantalla para grabar.",
        "Start a presentation first to record it.": "Iniciá una presentación primero para grabarla.",
        "Could not start the recording:": "No se pudo iniciar la grabación:",
        "Microphone access is off — recording without sound.":
            "Acceso al micrófono desactivado — grabando sin sonido.",
        "The recording ended up empty.": "La grabación terminó vacía.",
        "The recording stopped early, but what was captured was saved:":
            "La grabación se cortó antes de tiempo, pero lo capturado quedó guardado:",
        "No displays were available to annotate.": "No había pantallas disponibles para anotar.",
        "Reopen Presentify or check System Settings → Displays if this persists.": "Vuelve a abrir Presentify o revisa Ajustes del Sistema → Pantallas si continúa.",
        "Could not capture the screen:": "No se pudo capturar la pantalla:",
        "Could not capture the screen.": "No se pudo capturar la pantalla.",
    ]
}
