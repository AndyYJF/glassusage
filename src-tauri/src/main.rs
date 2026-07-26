// Release builds are GUI subsystem apps, so no console window flashes on launch.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    glassusage_lib::run();
}
