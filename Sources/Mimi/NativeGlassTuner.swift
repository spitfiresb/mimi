import AppKit
import os
#if !GLASS_PREVIEW
import ObjCShims
#endif

/// Tunes WindowServer's native material without obtaining desktop pixels.
/// The filter inputs are private macOS APIs; unknown layouts or exceptions
/// retain the stock native material instead of breaking dictation.
/// References: https://habr.com/ru/articles/1053570/
/// https://lrdcq.com/me/read.php/165.htm
@MainActor
final class NativeGlassTuner {
    private static let log = Logger(subsystem: "com.zainsaeed.mimi", category: "glass")
    private weak var view: NSGlassEffectView?
    private var timer: Timer?
    private let originals = NSMapTable<CALayer, NSArray>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let backdropOriginals = NSMapTable<CALayer, NSDictionary>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private weak var configuredWindow: NSWindow?
    private var originalAutoFlatten: Any?
    private var failed = false
    private var suspended = false
    private var loggedPresentation = false
    private(set) var presentationMatches = false
    var isRunning: Bool { timer != nil }

    init(view: NSGlassEffectView) { self.view = view }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil, !failed, view?.window?.isVisible == true else { return }
        // A flattened window can retain correct filter inputs while displaying
        // a frozen backdrop. Keep its layers hosted by WindowServer while shown.
        // https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview
        if let window = view?.window {
            let error = MMCatchException {
                originalAutoFlatten = window.value(forKey: "shouldAutoFlattenLayerTree")
                configuredWindow = window
                window.setValue(false, forKey: "shouldAutoFlattenLayerTree")
                window.setValue(false, forKey: "canHostLayersInWindowServer")
                window.setValue(true, forKey: "canHostLayersInWindowServer")
            }
            if let error {
                failed = true
                stop()
                Self.log.error("Native backdrop setup unavailable: \(error.localizedDescription)")
                return
            }
        }
        loggedPresentation = false
        tick()
        guard !failed else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Self.log.notice("Native glass lens active; no desktop capture")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        presentationMatches = false
        restore()
        if let window = configuredWindow, let originalAutoFlatten {
            _ = MMCatchException { window.setValue(originalAutoFlatten, forKey: "shouldAutoFlattenLayerTree") }
        }
        configuredWindow = nil
        originalAutoFlatten = nil
    }

    private func restore() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = MMCatchException {
            for layer in originals.keyEnumerator().allObjects.compactMap({ $0 as? CALayer }) {
                if let filters = originals.object(forKey: layer) { layer.filters = filters as? [Any] }
            }
            for layer in backdropOriginals.keyEnumerator().allObjects.compactMap({ $0 as? CALayer }) {
                for (key, value) in backdropOriginals.object(forKey: layer) ?? [:] {
                    if let key = key as? String { layer.setValue(value, forKey: key) }
                }
            }
        }
        originals.removeAllObjects()
        backdropOriginals.removeAllObjects()
        CATransaction.commit()
    }

    private func tick() {
        guard let view, view.window?.isVisible == true else { stop(); return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            if !suspended { restore() }
            suspended = true
            presentationMatches = false
            return
        }
        suspended = false
        guard let root = view.layer else { return }
        // Retain the reviewed 26 / 15.6 profile at the 52-point minimum height,
        // scaling with taller dictation panels as in the prototype.
        let depth = max(1, view.bounds.height / 2)
        let desired: [String: Any] = [
            "inputRefractionOpacity": 1.0,
            "inputInnerRefractionHeight": depth,
            "inputInnerRefractionAmount": depth * 0.6,
            "inputBlurRadius": 0.0,
            "inputBlurOpacity0": 0.0, "inputBlurOpacity1": 0.0,
            "inputBlurOpacity2": 0.0, "inputBlurOpacity3": 0.0,
            "inputBlurOpacity4": 0.0,
            "inputFaceColorMatrixWhite": 1.0,
            "inputFaceColorMatrixBlack": 0.0,
            "inputFaceColorMatrixSaturation": 1.0,
            "inputFaceColorMatrixFillColor": NSColor.clear.cgColor,
        ]
        var wrote = false
        var found = false
        var allPresented = true
        let savedFilters = originals
        let savedBackdrops = backdropOriginals
        let backdropSettings: [String: Bool] = [
            "windowServerAware": true,
            "allowsInPlaceFiltering": false,
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let error = MMCatchException {
            if let window = configuredWindow,
               (window.value(forKey: "shouldAutoFlattenLayerTree") as? NSNumber)?.boolValue != false {
                window.setValue(false, forKey: "shouldAutoFlattenLayerTree")
                wrote = true
            }
            func walk(_ layer: CALayer) {
                for filter in (layer.filters ?? []).compactMap({ $0 as? NSObject }) {
                    guard filter.responds(to: NSSelectorFromString("inputKeys")),
                          let keys = filter.value(forKey: "inputKeys") as? [String],
                          desired.keys.allSatisfy({ keys.contains($0) }),
                          filter.responds(to: NSSelectorFromString("name")),
                          let name = filter.value(forKey: "name") as? String,
                          !name.isEmpty, !name.contains(".") else { continue }
                    found = true
                    // This native layer defaults to windowServerAware=false.
                    // Explicitly enable behind-window sampling; filter-value
                    // verification alone cannot detect a stale source image.
                    for (key, value) in backdropSettings {
                        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
                        guard layer.responds(to: NSSelectorFromString(key)),
                              layer.responds(to: NSSelectorFromString(setter)) else { continue }
                        if (layer.value(forKey: key) as? NSNumber)?.boolValue != value {
                            let saved = (savedBackdrops.object(forKey: layer)?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()
                            if saved[key] == nil { saved[key] = layer.value(forKey: key) }
                            savedBackdrops.setObject(saved, forKey: layer)
                            layer.setValue(value, forKey: key)
                            wrote = true
                        }
                    }
                    let presented = (layer.presentation()?.filters ?? []).compactMap { $0 as? NSObject }.first {
                        $0.responds(to: NSSelectorFromString("name")) && ($0.value(forKey: "name") as? String) == name
                    }
                    let presentedKeys = presented?.responds(to: NSSelectorFromString("inputKeys")) == true
                        ? presented?.value(forKey: "inputKeys") as? [String] ?? [] : []
                    let changes = desired.filter { key, value in
                        let modelMatches = (filter.value(forKey: key) as? NSObject)?.isEqual(value) == true
                        let displayedMatches = presentedKeys.contains(key)
                            && (presented?.value(forKey: key) as? NSObject)?.isEqual(value) == true
                        if !displayedMatches { allPresented = false }
                        return !modelMatches || !displayedMatches
                    }
                    guard !changes.isEmpty else { continue }
                    if savedFilters.object(forKey: layer) == nil {
                        savedFilters.setObject((layer.filters ?? []).map { ($0 as? NSCopying)?.copy(with: nil) ?? $0 } as NSArray, forKey: layer)
                    }
                    // Named paths notify the renderer; changing a filter object
                    // alone previously left its presentation values stale.
                    for (key, value) in changes { layer.setValue(value, forKeyPath: "filters.\(name).\(key)") }
                    wrote = true
                }
                for child in layer.sublayers ?? [] { walk(child) }
            }
            walk(root)
        }
        CATransaction.commit()
        if let error {
            failed = true
            stop()
            Self.log.error("Native lens tuning unavailable; retaining system glass: \(error.localizedDescription)")
            return
        }
        if wrote { CATransaction.flush() }
        presentationMatches = found && allPresented
        if presentationMatches && !loggedPresentation {
            loggedPresentation = true
            Self.log.notice("Native glass lens filter values verified; live backdrop sampling configured")
        }
    }
}
