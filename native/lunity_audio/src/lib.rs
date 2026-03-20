//! PortAudio callback-based audio output for Lunity.
//! Uses the callback API (not blocking) for macOS compatibility.

use portaudio as pa;
use ringbuf::{HeapRb, traits::{Split, Producer, Consumer}};
use rustler::{Env, ResourceArc};
use std::sync::Mutex;

type StreamType = pa::Stream<pa::NonBlocking, pa::Output<i16>>;

struct AudioStreamInner {
    _pa: pa::PortAudio,
    stream: Mutex<Option<StreamType>>,
    producer: Mutex<ringbuf::HeapProd<i16>>,
}

impl AudioStreamInner {
    fn write(&self, samples: &[i16]) -> Result<(), String> {
        let mut producer = self.producer.lock().unwrap();
        for &s in samples {
            producer.try_push(s).map_err(|_| "ring buffer full")?;
        }
        Ok(())
    }

    fn stop(&self) -> Result<(), String> {
        let mut stream_guard = self.stream.lock().unwrap();
        if let Some(ref mut stream) = *stream_guard {
            stream.stop().map_err(|e| format!("{:?}", e))?;
        }
        Ok(())
    }

    fn close(&self) -> Result<(), String> {
        let mut stream_guard = self.stream.lock().unwrap();
        if let Some(mut stream) = stream_guard.take() {
            stream.close().map_err(|e| format!("{:?}", e))?;
        }
        Ok(())
    }
}

struct AudioStreamResource {
    inner: AudioStreamInner,
}

impl rustler::Resource for AudioStreamResource {}

fn on_load(env: Env, _info: rustler::Term) -> bool {
    env.register::<AudioStreamResource>().is_ok()
}

#[rustler::nif]
fn stream_open(
    sample_rate: f64,
    channels: i32,
    frames_per_buffer: u32,
) -> Result<ResourceArc<AudioStreamResource>, String> {
    let pa = pa::PortAudio::new().map_err(|e| format!("PortAudio init: {:?}", e))?;

    let mut settings = pa
        .default_output_stream_settings::<i16>(channels, sample_rate, frames_per_buffer)
        .map_err(|e| format!("default output settings: {:?}", e))?;
    settings.flags = pa::StreamFlags::CLIP_OFF;

    // Ring buffer: ~3 seconds of stereo at 48kHz = 288000 samples
    let capacity = (sample_rate * 3.0) as usize * channels as usize;
    let rb = HeapRb::<i16>::new(capacity);
    let (mut producer, consumer) = rb.split();

    // Pre-fill with silence to avoid underrun
    for _ in 0..(frames_per_buffer as usize * channels as usize * 4) {
        let _ = producer.try_push(0);
    }

    let mut consumer = consumer;
    let ch = channels;
    let callback = move |pa::OutputStreamCallbackArgs { buffer, frames, .. }| {
        let mut idx = 0;
        for _ in 0..frames {
            for _ in 0..ch {
                let sample = consumer.try_pop().unwrap_or(0);
                if idx < buffer.len() {
                    buffer[idx] = sample;
                    idx += 1;
                }
            }
        }
        pa::Continue
    };

    let mut stream = pa
        .open_non_blocking_stream(settings, callback)
        .map_err(|e| format!("open stream: {:?}", e))?;

    stream.start().map_err(|e| format!("start stream: {:?}", e))?;

    let inner = AudioStreamInner {
        _pa: pa,
        stream: Mutex::new(Some(stream)),
        producer: Mutex::new(producer),
    };

    Ok(ResourceArc::new(AudioStreamResource { inner }))
}

#[rustler::nif]
fn stream_write(resource: ResourceArc<AudioStreamResource>, data: rustler::Binary) -> Result<(), String> {
    if data.len() % 2 != 0 {
        return Err("data length must be multiple of 2 (16-bit samples)".to_string());
    }
    let samples: Vec<i16> = data
        .as_slice()
        .chunks_exact(2)
        .map(|c| i16::from_le_bytes([c[0], c[1]]))
        .collect();
    resource.inner.write(&samples)
}

#[rustler::nif]
fn stream_stop(resource: ResourceArc<AudioStreamResource>) -> Result<(), String> {
    resource.inner.stop()
}

#[rustler::nif]
fn stream_close(resource: ResourceArc<AudioStreamResource>) -> Result<(), String> {
    resource.inner.close()
}

rustler::init!("Elixir.Lunity.Audio.Native.Nif", load = on_load);
