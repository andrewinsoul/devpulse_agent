use crossterm::{
    cursor::{Hide, MoveTo, MoveUp, Show, MoveToColumn},
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{self, Clear, ClearType},
};
use rustler::{Encoder, Env, NifResult, Term};
use std::io::stdout;

#[rustler::nif]
fn ping() -> &'static str {
    "pong"
}

#[rustler::nif]
fn enable_raw_mode() -> Result<&'static str, String> {
    terminal::enable_raw_mode()
        .map(|_| "ok")
        .map_err(|e| e.to_string())
}

#[rustler::nif]
fn move_up(lines: u16) -> Result<&'static str, String> {
    execute!(
        stdout(),
        MoveUp(lines),
        MoveToColumn(0),
    )
    .map(|_| "ok")
    .map_err(|e| e.to_string())
}

#[rustler::nif]
fn disable_raw_mode() -> Result<&'static str, String> {
    terminal::disable_raw_mode()
        .map(|_| "ok")
        .map_err(|e| e.to_string())
}

#[rustler::nif]
fn read_key<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    loop {
        match event::read() {
            Ok(Event::Key(key)) => {
                // Ignore key release/repeat events
                if key.kind != KeyEventKind::Press {
                    continue;
                }

                if key.modifiers.contains(KeyModifiers::CONTROL) {
                    match key.code {
                        KeyCode::Char('c') => {
                            return Ok("ctrl_c".encode(env));
                        }
                        _ => {}
                    }
                }

                return Ok(match key.code {
                    KeyCode::Up => "up".encode(env),
                    KeyCode::Down => "down".encode(env),
                    KeyCode::Left => "left".encode(env),
                    KeyCode::Right => "right".encode(env),
                    KeyCode::Enter => "enter".encode(env),
                    KeyCode::Esc => "escape".encode(env),

                    KeyCode::Char(c) => {
                        let tuple = ("char", c.to_string());
                        tuple.encode(env)
                    }

                    _ => "unknown".encode(env),
                });
            }

            Ok(_) => continue,

            Err(err) => {
                let tuple = ("error", err.to_string());
                return Ok(tuple.encode(env));
            }
        }
    }
}

#[rustler::nif]
fn clear_screen() -> Result<&'static str, String> {
    execute!(
        stdout(),
        MoveTo(0, 0),
        Clear(ClearType::FromCursorDown)
    )
    .map(|_| "ok")
    .map_err(|e| e.to_string())
}

#[rustler::nif]
fn move_to(x: u16, y: u16) -> Result<&'static str, String> {
    execute!(stdout(), MoveTo(x, y))
        .map(|_| "ok")
        .map_err(|e| e.to_string())
}

#[rustler::nif]
fn hide_cursor() -> Result<&'static str, String> {
    execute!(stdout(), Hide)
        .map(|_| "ok")
        .map_err(|e| e.to_string())
}

#[rustler::nif]
fn show_cursor() -> Result<&'static str, String> {
    execute!(stdout(), Show)
        .map(|_| "ok")
        .map_err(|e| e.to_string())
}

rustler::init!("Elixir.DevpulseAgent.Utils.Terminal");