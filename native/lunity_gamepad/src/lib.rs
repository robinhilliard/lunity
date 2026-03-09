use gilrs::{Gilrs, Button, Axis, Event};
use rustler::{Env, NifStruct, Resource, ResourceArc};
use std::sync::Mutex;

#[derive(Debug, NifStruct)]
#[module = "Lunity.Input.Gamepad.Button"]
struct GamepadButton {
    pressed: bool,
    value: f64,
}

#[derive(Debug, NifStruct)]
#[module = "Lunity.Input.Gamepad"]
struct GamepadState {
    id: String,
    index: u32,
    connected: bool,
    mapping: String,
    axes: Vec<f64>,
    buttons: Vec<GamepadButton>,
    timestamp: i64,
}

struct GilrsResource {
    inner: Mutex<Gilrs>,
}

impl Resource for GilrsResource {}

fn on_load(env: Env, _info: rustler::Term) -> bool {
    env.register::<GilrsResource>().is_ok()
}

#[rustler::nif]
fn new() -> Result<ResourceArc<GilrsResource>, String> {
    match Gilrs::new() {
        Ok(gilrs) => Ok(ResourceArc::new(GilrsResource {
            inner: Mutex::new(gilrs),
        })),
        Err(e) => Err(format!("Failed to initialize gilrs: {}", e)),
    }
}

/// Standard axes in Web Gamepad API order:
/// [left_stick_x, left_stick_y, right_stick_x, right_stick_y]
const STANDARD_AXES: [Axis; 4] = [
    Axis::LeftStickX,
    Axis::LeftStickY,
    Axis::RightStickX,
    Axis::RightStickY,
];

/// Standard buttons in Web Gamepad API order (indices 0-16):
/// https://w3c.github.io/gamepad/#remapping
const STANDARD_BUTTONS: [Button; 17] = [
    Button::South,
    Button::East,
    Button::West,
    Button::North,
    Button::LeftTrigger,
    Button::RightTrigger,
    Button::LeftTrigger2,
    Button::RightTrigger2,
    Button::Select,
    Button::Start,
    Button::LeftThumb,
    Button::RightThumb,
    Button::DPadUp,
    Button::DPadDown,
    Button::DPadLeft,
    Button::DPadRight,
    Button::Mode,
];

#[rustler::nif]
fn poll(resource: ResourceArc<GilrsResource>) -> Vec<GamepadState> {
    let mut gilrs = resource.inner.lock().unwrap();

    while let Some(Event { .. }) = gilrs.next_event() {}

    let mut gamepads = Vec::new();

    for (id, gamepad) in gilrs.gamepads() {
        if !gamepad.is_connected() {
            continue;
        }

        let axes: Vec<f64> = STANDARD_AXES
            .iter()
            .map(|&axis| gamepad.value(axis) as f64)
            .collect();

        let buttons: Vec<GamepadButton> = STANDARD_BUTTONS
            .iter()
            .map(|&btn| {
                let pressed = gamepad.is_pressed(btn);
                let value = if pressed { 1.0 } else { 0.0 };
                GamepadButton { pressed, value }
            })
            .collect();

        let mapping_name = gamepad.map_name().unwrap_or("unknown");
        let mapping = if mapping_name != "unknown" {
            "standard".to_string()
        } else {
            "unknown".to_string()
        };

        gamepads.push(GamepadState {
            id: gamepad.name().to_string(),
            index: usize::from(id) as u32,
            connected: true,
            mapping,
            axes,
            buttons,
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0),
        });
    }

    gamepads
}

rustler::init!("Elixir.Lunity.Input.NativeGamepad.Nif", load = on_load);
