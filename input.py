"""Turns touches from the tablet into real mouse events on the virtual screen.

Coordinates arrive normalised (0..1 inside the video picture) so we don't care
what resolution the tablet is; we map them onto the target display's bounds.
"""
import Quartz

LEFT_DOWN = Quartz.kCGEventLeftMouseDown
LEFT_UP = Quartz.kCGEventLeftMouseUp
LEFT_DRAG = Quartz.kCGEventLeftMouseDragged
RIGHT_DOWN = Quartz.kCGEventRightMouseDown
RIGHT_UP = Quartz.kCGEventRightMouseUp
MOVE = Quartz.kCGEventMouseMoved


def display_bounds(index_from_end=0):
    """Bounds of the last active display - that's our virtual one."""
    import time
    ids = None
    for _ in range(20):          # the list is empty while macOS reshuffles screens
        err, ids, cnt = Quartz.CGGetActiveDisplayList(16, None, None)
        if ids:
            break
        time.sleep(0.25)
    did = list(ids)[-1 - index_from_end]
    b = Quartz.CGDisplayBounds(did)
    return did, b.origin.x, b.origin.y, b.size.width, b.size.height


class Pointer:
    def __init__(self):
        self.did, self.x0, self.y0, self.w, self.h = display_bounds()
        self.pos = (self.x0 + self.w / 2, self.y0 + self.h / 2)

    def to_screen(self, nx, ny):
        nx = min(max(nx, 0.0), 1.0)
        ny = min(max(ny, 0.0), 1.0)
        return (self.x0 + nx * self.w, self.y0 + ny * self.h)

    def post(self, kind, point, button=Quartz.kCGMouseButtonLeft, clicks=1):
        ev = Quartz.CGEventCreateMouseEvent(None, kind,
                                            Quartz.CGPointMake(point[0], point[1]), button)
        if clicks > 1:
            Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGMouseEventClickState, clicks)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def move(self, nx, ny):
        self.pos = self.to_screen(nx, ny)
        self.post(MOVE, self.pos)

    def down(self, nx, ny, right=False, clicks=1):
        self.pos = self.to_screen(nx, ny)
        self.post(RIGHT_DOWN if right else LEFT_DOWN, self.pos,
                  Quartz.kCGMouseButtonRight if right else Quartz.kCGMouseButtonLeft, clicks)

    def up(self, nx, ny, right=False, clicks=1):
        self.pos = self.to_screen(nx, ny)
        self.post(RIGHT_UP if right else LEFT_UP, self.pos,
                  Quartz.kCGMouseButtonRight if right else Quartz.kCGMouseButtonLeft, clicks)

    def drag(self, nx, ny):
        self.pos = self.to_screen(nx, ny)
        self.post(LEFT_DRAG, self.pos)

    def scroll(self, dx, dy):
        ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitPixel,
                                                  2, int(dy), int(dx))
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def handle(self, msg):
        t = msg.get("t")
        x, y = msg.get("x", 0.5), msg.get("y", 0.5)
        if t == "move":
            self.move(x, y)
        elif t == "down":
            self.down(x, y, msg.get("right", False), msg.get("clicks", 1))
        elif t == "up":
            self.up(x, y, msg.get("right", False), msg.get("clicks", 1))
        elif t == "drag":
            self.drag(x, y)
        elif t == "scroll":
            self.scroll(msg.get("dx", 0), msg.get("dy", 0))
