import CZebkit
import Foundation

#if canImport(IOSurface)
import IOSurface
#endif

/// The types of off-screen views (`WebView.offscreen(url:width:height:scale:context:)`):
/// their frames, and the input the application sends them.
///
/// An off-screen view has no window. The engine draws its page and hands
/// every frame to the application as a shared surface, without encoding: on
/// macOS an IOSurface, drawn by the GPU; on Linux BGRA pixels in shared
/// memory, or a dmabuf where the GPU makes one. Frames come only when the page
/// changes; an idle page sends none.
public enum Offscreen {
    /// A rectangle, in CSS pixels or in a frame's pixels as each use says.
    public struct Rect: Equatable, Hashable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(_ rect: zebkit_rect) {
            self.init(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height))
        }
    }

    /// Which layer of the view a frame is of.
    public enum Layer: Sendable {
        /// The view's page.
        case view
        /// A popup widget over it: a `<select>`'s list, a date or colour
        /// picker. Its frames are drawn at their `bounds` over the view's,
        /// until `WebView.onPopup` says it is gone.
        case popup
    }

    /// Pixel formats: 32 bits a pixel, alpha premultiplied, in memory order;
    /// sRGB.
    public enum PixelFormat: Sendable {
        /// B, G, R, A in memory: `DRM_FORMAT_ARGB8888`, `kCVPixelFormatType_32BGRA`.
        case bgra8
        /// R, G, B, A in memory: `DRM_FORMAT_ABGR8888`.
        case rgba8
    }

    /// What frames are made in, for `WebView.setFrameBuffers(_:)`.
    public enum FrameBuffers: Sendable {
        /// The fastest the platform has: IOSurfaces on macOS, shared memory
        /// on Linux. The default.
        case automatic
        /// Pixels in shared memory, everywhere.
        case sharedMemory
        /// GPU buffers: IOSurfaces, dmabufs on Linux where the GPU makes
        /// them (shared memory where it does not).
        case gpu

        var raw: zebkit_frame_buffers {
            switch self {
            case .automatic: ZEBKIT_BUFFERS_AUTO
            case .sharedMemory: ZEBKIT_BUFFERS_SHARED_MEMORY
            case .gpu: ZEBKIT_BUFFERS_GPU
            }
        }
    }

    /// Pixels in shared memory, the engine's until the frame is released.
    public struct SharedMemory {
        /// The pixels in this process: the first pixel's row first, `stride`
        /// bytes a row. Valid until the frame is released.
        public let pixels: UnsafeRawBufferPointer
        /// Bytes a row.
        public let stride: Int
        /// The engine's file descriptor, open until the frame is released:
        /// `mmap(size bytes at 0, PROT_READ, MAP_SHARED)`, the pixels at
        /// `offset`, or send it to another process (`SCM_RIGHTS`); `dup()`
        /// it to keep it.
        public let fileDescriptor: Int32
        /// The size of what `fileDescriptor` maps, in bytes.
        public let size: Int
        /// Where the pixels start in what `fileDescriptor` maps.
        public let offset: Int
    }

    /// A plane of a dmabuf.
    public struct Plane: Equatable, Sendable {
        /// The engine's file descriptor, open until the frame is released.
        public let fileDescriptor: Int32
        /// Bytes a row.
        public let stride: Int
        /// Where the plane starts in its buffer.
        public let offset: Int
    }

    /// A dmabuf (Linux), the engine's until the frame is released.
    public struct Dmabuf: Equatable, Sendable {
        public let planes: [Plane]
        /// The DRM format modifier.
        public let modifier: UInt64
        /// The DRM format.
        public let fourcc: UInt32
    }

    /// Where a frame's pixels are. Every pointer and file descriptor in it is
    /// the engine's, and good only until the frame is released.
    public enum Buffer {
        case sharedMemory(SharedMemory)
        /// An `IOSurfaceRef` (macOS), the engine's until the frame is
        /// released; `CFRetain()` it to keep it. `Frame.ioSurface` gives it
        /// typed.
        case ioSurface(UnsafeMutableRawPointer)
        case dmabuf(Dmabuf)
    }

    /// A frame of an off-screen view: the whole picture, and what changed
    /// since the layer's previous frame.
    ///
    /// Its buffer is the application's to read until the frame is released,
    /// by `release()` or when the last reference to it goes, whichever is
    /// first: the engine gets each frame back exactly once, also after its
    /// view has closed. While the application holds as many frames as
    /// `WebView.setMaxFramesInFlight(_:)` allows, the engine keeps only the
    /// newest of the rest, with the damage of those it skipped. A frame may
    /// go to any thread, and be released from any.
    public final class Frame: @unchecked Sendable, CustomStringConvertible {
        // The engine's frame, until it is given back; guarded by `lock`.
        private nonisolated(unsafe) var raw: UnsafePointer<zebkit_frame>?
        private let lock = NSLock()

        /// 1, 2, 3, ... for each layer of a view (a popup's start again at
        /// 1). A gap means frames were skipped; this one carries their damage.
        public let sequence: UInt64
        public let layer: Layer
        /// Where the frame goes in the view, in CSS pixels: (0, 0, width,
        /// height) for the view; for a popup, its place, which may reach past
        /// the view's edges.
        public let bounds: Rect
        /// The frame's size in pixels.
        public let width: Int
        public let height: Int
        /// Device pixels per CSS pixel.
        public let scale: Double
        /// What changed since the previous frame of this layer, in the
        /// frame's pixels; the whole frame when its size changed or it is the
        /// first. The frame always holds the whole picture.
        public let damage: [Rect]
        /// When the compositor means the frame to be shown, in microseconds
        /// of the system's monotonic clock (`mach_absolute_time()` on macOS,
        /// `CLOCK_MONOTONIC` elsewhere).
        public let drawnMicroseconds: Int64
        /// When the frame was ready, on the same clock.
        public let readyMicroseconds: Int64
        public let format: PixelFormat
        /// The same for every frame in the same buffer while the buffer
        /// lives: an application can keep a mapping or a texture per buffer.
        public let bufferID: UInt64
        /// Where the pixels are; good until the frame is released.
        public let buffer: Buffer

        /// Takes the engine's frame, which this object gives back.
        init(taking frame: UnsafePointer<zebkit_frame>) {
            raw = frame
            let f = frame.pointee
            sequence = f.sequence
            layer = f.layer == ZEBKIT_LAYER_POPUP ? .popup : .view
            bounds = Rect(f.bounds)
            width = Int(max(f.width, 0))
            height = Int(max(f.height, 0))
            scale = Double(f.scale)
            damage = f.damage.map { pointer in (0..<f.damage_count).map { Rect(pointer[$0]) } } ?? []
            drawnMicroseconds = f.drawn_us
            readyMicroseconds = f.ready_us
            format = f.format == ZEBKIT_FORMAT_RGBA8 ? .rgba8 : .bgra8
            bufferID = f.buffer_id
            switch f.kind {
            case ZEBKIT_FRAME_IOSURFACE where f.iosurface != nil:
                buffer = .ioSurface(f.iosurface)
            case ZEBKIT_FRAME_DMABUF:
                let fds = [f.fds.0, f.fds.1, f.fds.2, f.fds.3]
                let strides = [f.strides.0, f.strides.1, f.strides.2, f.strides.3]
                let offsets = [f.offsets.0, f.offsets.1, f.offsets.2, f.offsets.3]
                let planes = (0..<Int(min(max(f.plane_count, 0), 4))).map {
                    Plane(fileDescriptor: fds[$0], stride: Int(strides[$0]), offset: Int(offsets[$0]))
                }
                buffer = .dmabuf(Dmabuf(planes: planes, modifier: f.modifier, fourcc: f.fourcc))
            default:
                // Shared memory; also an IOSurface frame with no surface, or a D3D11 frame, which this package
                // does not read: an empty buffer.
                let width = Int(max(f.width, 0))
                let height = Int(max(f.height, 0))
                let count = height > 0 ? f.stride * (height - 1) + width * 4 : 0
                buffer = .sharedMemory(
                    SharedMemory(
                        pixels: UnsafeRawBufferPointer(start: f.pixels, count: f.pixels == nil ? 0 : count),
                        stride: f.stride, fileDescriptor: f.fd, size: f.size, offset: f.offset))
            }
        }

        deinit {
            release()
        }

        /// Gives the frame back: its buffer may be drawn into again, and
        /// nothing of `buffer` may be used after. Any thread; once is what
        /// counts, later calls do nothing.
        public func release() {
            lock.lock()
            let frame = raw
            raw = nil
            lock.unlock()
            if let frame { zebkit_frame_release(frame) }
        }

        /// Whether the frame has been given back.
        public var isReleased: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raw == nil
        }

        #if os(macOS)
        /// A new send right to the frame's IOSurface, for another process:
        /// `IOSurfaceLookupFromMachPort()` there. The caller's, to send in a
        /// mach message or `mach_port_deallocate()`. `nil` for another kind of
        /// frame, or once the frame is released.
        public func makeIOSurfaceMachPort() -> UInt32? {
            lock.lock()
            defer { lock.unlock() }
            guard let raw else { return nil }
            let port = zebkit_frame_iosurface_mach_port(raw)
            return port == 0 ? nil : port
        }
        #endif

        #if canImport(IOSurface)
        /// The frame's IOSurface, for an `.ioSurface` frame. Holding it keeps
        /// the surface alive, but the engine draws into it again once the
        /// frame is released: read it before. A `CVPixelBuffer` is
        /// `CVPixelBufferCreateWithIOSurface()`, a Metal texture
        /// `MTLDevice.makeTexture(descriptor:iosurface:plane:)`.
        public var ioSurface: IOSurfaceRef? {
            guard case .ioSurface(let pointer) = buffer, !isReleased else { return nil }
            return Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
        }
        #endif

        public var description: String {
            let kind: String
            switch buffer {
            case .sharedMemory: kind = "sharedMemory"
            case .ioSurface: kind = "ioSurface"
            case .dmabuf: kind = "dmabuf"
            }
            return "Frame(\(sequence), \(layer), \(width)x\(height) @\(scale), \(kind), damage: \(damage.count))"
        }
    }

    // MARK: Input

    /// Modifier keys and buttons held, for every event; also for the drags of
    /// every view, with a window or without (`WebView.dragEnter(dataJSON:x:y:operations:modifiers:)`).
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: ZEBKIT_MODIFIER_SHIFT.rawValue)
        public static let control = Modifiers(rawValue: ZEBKIT_MODIFIER_CONTROL.rawValue)
        /// Option on macOS.
        public static let alt = Modifiers(rawValue: ZEBKIT_MODIFIER_ALT.rawValue)
        /// Command on macOS, the Super key elsewhere.
        public static let meta = Modifiers(rawValue: ZEBKIT_MODIFIER_META.rawValue)
        public static let capsLock = Modifiers(rawValue: ZEBKIT_MODIFIER_CAPS_LOCK.rawValue)
        public static let numLock = Modifiers(rawValue: ZEBKIT_MODIFIER_NUM_LOCK.rawValue)
        public static let leftButton = Modifiers(rawValue: ZEBKIT_MODIFIER_LEFT_BUTTON.rawValue)
        public static let middleButton = Modifiers(rawValue: ZEBKIT_MODIFIER_MIDDLE_BUTTON.rawValue)
        public static let rightButton = Modifiers(rawValue: ZEBKIT_MODIFIER_RIGHT_BUTTON.rawValue)
        /// A key of the numeric keypad.
        public static let keypad = Modifiers(rawValue: ZEBKIT_MODIFIER_KEYPAD.rawValue)
        /// A key held down, repeating.
        public static let autoRepeat = Modifiers(rawValue: ZEBKIT_MODIFIER_AUTO_REPEAT.rawValue)
    }

    /// What a mouse event is.
    public enum MouseEventType: Sendable {
        case move
        case down
        case up
        /// The pointer left the view.
        case leave

        var raw: zebkit_mouse_type {
            switch self {
            case .move: ZEBKIT_MOUSE_MOVE
            case .down: ZEBKIT_MOUSE_DOWN
            case .up: ZEBKIT_MOUSE_UP
            case .leave: ZEBKIT_MOUSE_LEAVE
            }
        }
    }

    public enum MouseButton: Sendable {
        case none
        case left
        case middle
        case right
        case back
        case forward

        var raw: zebkit_mouse_button {
            switch self {
            case .none: ZEBKIT_BUTTON_NONE
            case .left: ZEBKIT_BUTTON_LEFT
            case .middle: ZEBKIT_BUTTON_MIDDLE
            case .right: ZEBKIT_BUTTON_RIGHT
            case .back: ZEBKIT_BUTTON_BACK
            case .forward: ZEBKIT_BUTTON_FORWARD
            }
        }
    }

    /// A trackpad gesture's phase, or `.none` for a mouse's wheel.
    public enum WheelPhase: Sendable {
        case none
        case began
        case changed
        case ended
        /// The scroll going on after the fingers left.
        case momentum

        var raw: zebkit_wheel_phase {
            switch self {
            case .none: ZEBKIT_WHEEL_PHASE_NONE
            case .began: ZEBKIT_WHEEL_PHASE_BEGAN
            case .changed: ZEBKIT_WHEEL_PHASE_CHANGED
            case .ended: ZEBKIT_WHEEL_PHASE_ENDED
            case .momentum: ZEBKIT_WHEEL_PHASE_MOMENTUM
            }
        }
    }

    /// What a key event is.
    public enum KeyEventType: Sendable {
        /// A key pressed: what `keydown` sees, without the character.
        case down
        case up
        /// The character a key typed, after its `.down`: what `keypress` and
        /// the text input see.
        case char

        var raw: zebkit_key_type {
            switch self {
            case .down: ZEBKIT_KEY_DOWN
            case .up: ZEBKIT_KEY_UP
            case .char: ZEBKIT_KEY_CHAR
            }
        }
    }

    /// A key, for `WebView.sendKey(_:)`. For a key that types, send `.down`,
    /// then `.char` with its text, then `.up`, as the system gives them.
    public struct KeyEvent: Equatable, Sendable {
        public var type: KeyEventType
        public var modifiers: Modifiers
        /// The key's Windows virtual key code, which is the DOM's `keyCode`
        /// (0x41 for A, 0x0D for Enter); 0 for none.
        public var keyCode: Int
        /// The system's own code for the key, or 0.
        public var nativeKeyCode: Int
        /// The DOM's `code` (`"KeyA"`, `"Enter"`); `nil` to leave it to the engine.
        public var code: String?
        /// The DOM's `key` (`"a"`, `"Enter"`); `nil` to leave it to the engine.
        public var key: String?
        /// For `.char`: the text typed, one character as a rule. `nil` otherwise.
        public var text: String?
        /// For `.char`: what it would be without the modifiers. `nil` otherwise.
        public var unmodifiedText: String?

        public init(
            _ type: KeyEventType, modifiers: Modifiers = [], keyCode: Int = 0, nativeKeyCode: Int = 0,
            code: String? = nil, key: String? = nil, text: String? = nil, unmodifiedText: String? = nil
        ) {
            self.type = type
            self.modifiers = modifiers
            self.keyCode = keyCode
            self.nativeKeyCode = nativeKeyCode
            self.code = code
            self.key = key
            self.text = text
            self.unmodifiedText = unmodifiedText
        }

        /// Calls `body` with the event as C has it, its strings alive for the call.
        func withRaw<Result>(_ body: (UnsafePointer<zebkit_key_event>) -> Result) -> Result {
            code.withOptionalCString { code in
                key.withOptionalCString { key in
                    text.withOptionalCString { text in
                        unmodifiedText.withOptionalCString { unmodifiedText in
                            var event = zebkit_key_event(
                                type: type.raw, modifiers: modifiers.rawValue, key_code: Int32(clamping: keyCode),
                                native_key_code: Int32(clamping: nativeKeyCode), code: code, key: key, text: text,
                                unmodified_text: unmodifiedText)
                            return body(&event)
                        }
                    }
                }
            }
        }
    }

    /// A native key-binding command, as AppKit's `doCommandBySelector:` gives
    /// them: `MoveWordLeft`, `DeleteBackward`, `SelectAll`, ... with a value
    /// for the few that take one. For `WebView.sendKey(_:commands:)`.
    public struct EditCommand: Equatable, Sendable {
        public var name: String
        public var value: String?

        public init(_ name: String, value: String? = nil) {
            self.name = name
            self.value = value
        }
    }

    /// A cursor the page asks for that is an image of its own.
    public struct CursorImage: Equatable, Sendable {
        /// `width` by `height` BGRA pixels, alpha premultiplied, 4 bytes a pixel.
        public let pixels: Data
        public let width: Int
        public let height: Int
        /// The hot spot.
        public let hotX: Int
        public let hotY: Int
        /// Device pixels per CSS pixel.
        public let scale: Double
    }

    /// The cursor the page asks for.
    public struct Cursor: Equatable, Sendable {
        /// As CSS names it: `"default"`, `"pointer"`, `"text"`, `"wait"`,
        /// `"crosshair"`, `"move"`, `"not-allowed"`, `"grab"`,
        /// `"ew-resize"`, ..., `"none"`, or `"custom"` with `image`.
        public let name: String
        /// The picture of a `"custom"` cursor; `nil` for the others.
        public let image: CursorImage?
    }
}
