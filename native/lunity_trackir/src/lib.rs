use rustler::{Env, NifStruct, Resource, ResourceArc};
use std::sync::Mutex;

#[derive(Debug, NifStruct)]
#[module = "Lunity.Input.HeadPose"]
struct HeadPose {
    yaw: f64,
    pitch: f64,
    roll: f64,
    x: f64,
    y: f64,
    z: f64,
    frame: u32,
}

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------
#[cfg(windows)]
mod platform {
    use super::*;
    use libloading::Library;
    use std::os::raw::c_ulong;

    const NP_MAX_VALUE: f32 = 16383.0;
    const NP_MAX_ROTATION: f32 = 180.0;
    const NP_MAX_TRANSLATION: f32 = 50.0;

    #[repr(C, packed)]
    struct TrackIRData {
        status: u16,
        frame_signature: u16,
        io_data: c_ulong,
        roll: f32,
        pitch: f32,
        yaw: f32,
        x: f32,
        y: f32,
        z: f32,
        _reserved: [f32; 9],
    }

    type NpResult = i32;
    const NP_OK: NpResult = 0;

    type FnRegisterWindowHandle = unsafe extern "system" fn(usize) -> NpResult;
    type FnUnregisterWindowHandle = unsafe extern "system" fn() -> NpResult;
    type FnRegisterProgramProfileId = unsafe extern "system" fn(u16) -> NpResult;
    type FnRequestData = unsafe extern "system" fn(u16) -> NpResult;
    type FnGetData = unsafe extern "system" fn(*mut TrackIRData) -> NpResult;
    type FnStartDataTransmission = unsafe extern "system" fn() -> NpResult;
    type FnStopDataTransmission = unsafe extern "system" fn() -> NpResult;
    type FnGetSignature = unsafe extern "system" fn(*mut SignatureData) -> NpResult;

    #[repr(C)]
    struct SignatureData {
        dll_signature: [u8; 200],
        app_signature: [u8; 200],
    }

    pub struct TrackIRResource {
        _library: Library,
        get_data: FnGetData,
        stop_transmission: FnStopDataTransmission,
        unregister_handle: FnUnregisterWindowHandle,
    }

    // Safety: the DLL function pointers are stable for the lifetime of the Library
    unsafe impl Send for TrackIRResource {}
    unsafe impl Sync for TrackIRResource {}

    impl Drop for TrackIRResource {
        fn drop(&mut self) {
            unsafe {
                (self.stop_transmission)();
                (self.unregister_handle)();
            }
        }
    }

    fn find_dll_from_registry() -> Option<String> {
        use winreg::enums::*;
        use winreg::RegKey;

        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let key = hkcu
            .open_subkey("Software\\NaturalPoint\\NATURALPOINT\\NPClient Location")
            .ok()?;
        let path: String = key.get_value("Path").ok()?;
        Some(path)
    }

    pub fn init_trackir(
        dll_path_opt: Option<String>,
        hwnd: usize,
        developer_id: u16,
    ) -> Result<TrackIRResource, String> {
        let dll_dir = match dll_path_opt {
            Some(p) if !p.is_empty() => p,
            _ => find_dll_from_registry()
                .ok_or_else(|| "TrackIR DLL path not found in registry".to_string())?,
        };

        let dll_file = format!("{}NPClient64.dll", dll_dir);

        let lib = unsafe { Library::new(&dll_file) }
            .map_err(|e| format!("Failed to load {}: {}", dll_file, e))?;

        unsafe {
            let get_signature: FnGetSignature = *lib
                .get(b"NP_GetSignature\0")
                .map_err(|e| format!("NP_GetSignature: {}", e))?;

            let mut sig = std::mem::zeroed::<SignatureData>();
            let r = get_signature(&mut sig);
            if r != NP_OK {
                return Err(format!("NP_GetSignature failed: {}", r));
            }

            let expected_dll = b"precise head tracking\n put your head into the game\n now go look around\n\n Copyright EyeControl Technologies";
            let expected_app = b"hardware camera\n software processing data\n track user movement\n\n Copyright EyeControl Technologies";

            if !sig.dll_signature.starts_with(expected_dll)
                || !sig.app_signature.starts_with(expected_app)
            {
                return Err("DLL signature verification failed".to_string());
            }

            let register_handle: FnRegisterWindowHandle = *lib
                .get(b"NP_RegisterWindowHandle\0")
                .map_err(|e| format!("NP_RegisterWindowHandle: {}", e))?;
            let unregister_handle: FnUnregisterWindowHandle = *lib
                .get(b"NP_UnregisterWindowHandle\0")
                .map_err(|e| format!("NP_UnregisterWindowHandle: {}", e))?;
            let register_profile: FnRegisterProgramProfileId = *lib
                .get(b"NP_RegisterProgramProfileID\0")
                .map_err(|e| format!("NP_RegisterProgramProfileID: {}", e))?;
            let request_data: FnRequestData = *lib
                .get(b"NP_RequestData\0")
                .map_err(|e| format!("NP_RequestData: {}", e))?;
            let get_data: FnGetData = *lib
                .get(b"NP_GetData\0")
                .map_err(|e| format!("NP_GetData: {}", e))?;
            let start_transmission: FnStartDataTransmission = *lib
                .get(b"NP_StartDataTransmission\0")
                .map_err(|e| format!("NP_StartDataTransmission: {}", e))?;
            let stop_transmission: FnStopDataTransmission = *lib
                .get(b"NP_StopDataTransmission\0")
                .map_err(|e| format!("NP_StopDataTransmission: {}", e))?;

            // Unregister any stale handle from a previous crashed session
            unregister_handle();

            let r = register_handle(hwnd);
            if r != NP_OK {
                return Err(format!(
                    "NP_RegisterWindowHandle failed: {} (hwnd={})",
                    r, hwnd
                ));
            }

            let r = register_profile(developer_id);
            if r != NP_OK {
                unregister_handle();
                return Err(format!("NP_RegisterProgramProfileID failed: {}", r));
            }

            // Request all 6 DOF: pitch(2) | yaw(4) | roll(1) | x(16) | y(32) | z(64)
            let data_fields: u16 = 1 | 2 | 4 | 16 | 32 | 64;
            let r = request_data(data_fields);
            if r != NP_OK {
                unregister_handle();
                return Err(format!("NP_RequestData failed: {}", r));
            }

            let r = start_transmission();
            if r != NP_OK {
                unregister_handle();
                return Err(format!("NP_StartDataTransmission failed: {}", r));
            }

            Ok(TrackIRResource {
                _library: lib,
                get_data,
                stop_transmission,
                unregister_handle,
            })
        }
    }

    pub fn poll_trackir(resource: &TrackIRResource) -> Result<HeadPose, String> {
        unsafe {
            let mut tid = std::mem::zeroed::<TrackIRData>();
            let r = (resource.get_data)(&mut tid);
            if r != NP_OK {
                return Err(format!("NP_GetData failed: {}", r));
            }

            // Status 0 = NPSTATUS_REMOTEACTIVE
            if tid.status != 0 {
                return Err("TrackIR not active (mouse emulation mode)".to_string());
            }

            Ok(HeadPose {
                yaw: (tid.yaw as f64 / NP_MAX_VALUE as f64) * NP_MAX_ROTATION as f64,
                pitch: (tid.pitch as f64 / NP_MAX_VALUE as f64) * NP_MAX_ROTATION as f64,
                roll: (tid.roll as f64 / NP_MAX_VALUE as f64) * NP_MAX_ROTATION as f64,
                x: (tid.x as f64 / NP_MAX_VALUE as f64) * NP_MAX_TRANSLATION as f64,
                y: (tid.y as f64 / NP_MAX_VALUE as f64) * NP_MAX_TRANSLATION as f64,
                z: (tid.z as f64 / NP_MAX_VALUE as f64) * NP_MAX_TRANSLATION as f64,
                frame: tid.frame_signature as u32,
            })
        }
    }
}

// ---------------------------------------------------------------------------
// Shared resource wrapper
// ---------------------------------------------------------------------------

struct TrackIRWrapper {
    #[cfg(windows)]
    inner: Mutex<platform::TrackIRResource>,
    #[cfg(not(windows))]
    _phantom: (),
}

impl Resource for TrackIRWrapper {}

fn on_load(env: Env, _info: rustler::Term) -> bool {
    env.register::<TrackIRWrapper>().is_ok()
}

// ---------------------------------------------------------------------------
// NIF functions
// ---------------------------------------------------------------------------

#[cfg(windows)]
#[rustler::nif]
fn init(
    dll_path: String,
    hwnd: u64,
    developer_id: u32,
) -> Result<ResourceArc<TrackIRWrapper>, String> {
    let path_opt = if dll_path.is_empty() {
        None
    } else {
        Some(dll_path)
    };

    let resource = platform::init_trackir(path_opt, hwnd as usize, developer_id as u16)?;

    Ok(ResourceArc::new(TrackIRWrapper {
        inner: Mutex::new(resource),
    }))
}

#[cfg(not(windows))]
#[rustler::nif]
fn init(
    _dll_path: String,
    _hwnd: u64,
    _developer_id: u32,
) -> Result<ResourceArc<TrackIRWrapper>, String> {
    Err("TrackIR is only supported on Windows".to_string())
}

#[cfg(windows)]
#[rustler::nif]
fn poll(resource: ResourceArc<TrackIRWrapper>) -> Result<HeadPose, String> {
    let guard = resource.inner.lock().unwrap();
    platform::poll_trackir(&guard)
}

#[cfg(not(windows))]
#[rustler::nif]
fn poll(_resource: ResourceArc<TrackIRWrapper>) -> Result<HeadPose, String> {
    Err("TrackIR is only supported on Windows".to_string())
}

rustler::init!("Elixir.Lunity.Input.NativeTrackIR.Nif", load = on_load);
