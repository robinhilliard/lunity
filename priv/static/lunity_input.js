/**
 * Lunity browser input capture.
 *
 * Sends keyboard, mouse, and gamepad state over a WebSocket using the
 * same canonical format that the native backend produces. The server
 * writes directly to the input session ETS table.
 *
 * Usage:
 *   const ws = new WebSocket("ws://localhost:4111/ws/viewer");
 *   const input = new LunityInput(ws);
 *   input.start();
 *   // later:
 *   input.stop();
 */
class LunityInput {
  constructor(socket, opts = {}) {
    this.socket = socket;
    this.gamepadPollMs = opts.gamepadPollMs || 16;
    this._gamepadTimer = null;
    this._boundHandlers = {};
  }

  start() {
    this._bindKeyboard();
    this._bindMouse();
    this._startGamepadPolling();
  }

  stop() {
    this._unbindKeyboard();
    this._unbindMouse();
    this._stopGamepadPolling();
  }

  _send(msg) {
    if (this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(msg));
    }
  }

  // -- Keyboard ---------------------------------------------------------------

  _bindKeyboard() {
    this._boundHandlers.keydown = (e) => {
      this._send({ type: "key_down", code: e.code });
    };
    this._boundHandlers.keyup = (e) => {
      this._send({ type: "key_up", code: e.code });
    };
    window.addEventListener("keydown", this._boundHandlers.keydown);
    window.addEventListener("keyup", this._boundHandlers.keyup);
  }

  _unbindKeyboard() {
    window.removeEventListener("keydown", this._boundHandlers.keydown);
    window.removeEventListener("keyup", this._boundHandlers.keyup);
  }

  // -- Mouse ------------------------------------------------------------------

  _bindMouse() {
    this._boundHandlers.pointermove = (e) => {
      this._send({ type: "mouse_move", x: e.clientX, y: e.clientY });
    };
    this._boundHandlers.pointerdown = (e) => {
      this._send({
        type: "mouse_button",
        button: this._pointerButton(e.button),
        pressed: true,
      });
    };
    this._boundHandlers.pointerup = (e) => {
      this._send({
        type: "mouse_button",
        button: this._pointerButton(e.button),
        pressed: false,
      });
    };
    this._boundHandlers.wheel = (e) => {
      this._send({ type: "mouse_wheel", delta: e.deltaY });
    };

    window.addEventListener("pointermove", this._boundHandlers.pointermove);
    window.addEventListener("pointerdown", this._boundHandlers.pointerdown);
    window.addEventListener("pointerup", this._boundHandlers.pointerup);
    window.addEventListener("wheel", this._boundHandlers.wheel);
  }

  _unbindMouse() {
    window.removeEventListener("pointermove", this._boundHandlers.pointermove);
    window.removeEventListener("pointerdown", this._boundHandlers.pointerdown);
    window.removeEventListener("pointerup", this._boundHandlers.pointerup);
    window.removeEventListener("wheel", this._boundHandlers.wheel);
  }

  _pointerButton(button) {
    switch (button) {
      case 0:
        return "left";
      case 1:
        return "middle";
      case 2:
        return "right";
      default:
        return "left";
    }
  }

  // -- Gamepad ----------------------------------------------------------------

  _startGamepadPolling() {
    this._gamepadTimer = setInterval(() => {
      const gamepads = navigator.getGamepads();
      for (const gp of gamepads) {
        if (!gp) continue;
        this._send({
          type: "gamepad",
          index: gp.index,
          id: gp.id,
          axes: [...gp.axes],
          buttons: gp.buttons.map((b) => ({
            pressed: b.pressed,
            value: b.value,
          })),
          mapping: gp.mapping || "unknown",
          connected: gp.connected,
          timestamp: gp.timestamp,
        });
      }
    }, this.gamepadPollMs);
  }

  _stopGamepadPolling() {
    if (this._gamepadTimer) {
      clearInterval(this._gamepadTimer);
      this._gamepadTimer = null;
    }
  }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = LunityInput;
}
