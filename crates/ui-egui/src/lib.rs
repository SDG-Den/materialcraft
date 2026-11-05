//! # materialcraft-ui-egui
//!
//! The MaterialCraft desktop and web shell: a dense dark professional layout (menu bar, main
//! toolbar, explorer, library, node graph editor, 3D and 2D views, properties, status bar). It is
//! a thin layer: every edit goes through `materialcraft-engine` commands, so the CLI, the control
//! channel and MCP can do the same.
#![forbid(unsafe_code)]
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

pub mod control;
pub mod cook;
pub mod docking;
pub mod explorer;
pub mod function_editor;
pub mod graph_view;
pub mod i18n;
pub mod library;
pub mod menus;
pub mod properties;
pub mod state;
pub mod theme;
pub mod thumbs;
pub mod toolbar;
pub mod view2d;
pub mod view3d;
pub mod web_files;
pub mod widgets;
pub mod windows;

use std::collections::VecDeque;

use craft_ui::theme::palette::Palette;
use materialcraft_engine::Session;
use serde_json::Value;

pub use control::ControlRequest;
pub use state::UiState;

pub struct Toast {
    pub text: String,
    pub error: bool,
    pub until: f64,
}

pub struct MaterialCraftApp {
    pub session: Session,
    pub ui: UiState,
    pub control: Option<std::sync::mpsc::Receiver<ControlRequest>>,
    pub toasts: Vec<Toast>,
    /// Background cooking of the open graph.
    pub cooker: cook::Cooker,
    /// Node output thumbnails and library previews.
    pub thumbs: thumbs::Thumbs,
    /// The graph editor's gesture state.
    pub graph: graph_view::GraphView,
    pub view3d: view3d::View3dState,
    pub view2d: view2d::View2dState,
    /// The function graph editor window, when open.
    pub fn_editor: Option<function_editor::FnEditor>,
    /// Synthetic input from the control channel, fed to egui on the next frames.
    pub input_queue: VecDeque<control::Scripted>,
    /// Replies waiting for the next window capture (`ui.screenshot`).
    pub pending_screenshots: Vec<std::sync::mpsc::Sender<Value>>,
    pub fps: f32,
    /// Smoothed CPU time spent building the UI per frame (ms).
    pub ui_ms: f32,
    /// The last status message (bottom left).
    pub status: String,
    last_time: f64,
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    next_autosave: f64,
    styled: Option<(theme::Brightness, theme::Accent, u64)>,
    /// The suite palette loaded at startup or by the watcher. `None` keeps the built-in theme.
    palette: Option<Palette>,
    palette_revision: u64,
    #[cfg(not(target_arch = "wasm32"))]
    palette_watcher: craft_ui::theme::PaletteWatcher,
    /// The icon font is installed (it takes effect on the frame after `set_fonts`).
    fonts_ready: bool,
}

impl MaterialCraftApp {
    pub fn new(cc: &eframe::CreationContext<'_>, session: Session) -> MaterialCraftApp {
        let ui = cc.storage.and_then(|s| eframe::get_value::<UiState>(s, "ui")).unwrap_or_default();
        theme::install(&cc.egui_ctx);
        let mut app = MaterialCraftApp::headless(session, ui);
        app.fonts_ready = true;
        app.ui.windows.home = app.ui.prefs.show_home;
        app
    }

    /// An app without eframe (offscreen snapshots and tests): fonts are installed on the first
    /// frame, which draws nothing.
    pub fn headless(session: Session, mut ui: UiState) -> MaterialCraftApp {
        ui.windows = state::Windows::default();
        ui.frame_all = true;
        let next_autosave = ui.prefs.autosave_minutes as f64 * 60.0;
        #[cfg(not(target_arch = "wasm32"))]
        let palette = Palette::load().map(|loaded| loaded.palette);
        #[cfg(target_arch = "wasm32")]
        let palette: Option<Palette> = None;
        let mut app = MaterialCraftApp {
            session,
            ui,
            control: None,
            toasts: Vec::new(),
            cooker: cook::Cooker::default(),
            thumbs: thumbs::Thumbs::default(),
            graph: graph_view::GraphView::default(),
            view3d: view3d::View3dState::default(),
            view2d: view2d::View2dState::default(),
            fn_editor: None,
            input_queue: VecDeque::new(),
            pending_screenshots: Vec::new(),
            fps: 0.0,
            ui_ms: 0.0,
            status: String::new(),
            last_time: 0.0,
            next_autosave,
            styled: None,
            palette,
            palette_revision: 0,
            #[cfg(not(target_arch = "wasm32"))]
            palette_watcher: craft_ui::theme::PaletteWatcher::from_env(),
            fonts_ready: false,
        };
        app.apply_prefs();
        app
    }

    /// Push the preferences that live in the session (preview size).
    pub fn apply_prefs(&mut self) {
        let p = if self.ui.prefs.preview_size == 0 { None } else { Some(self.ui.prefs.preview_size.clamp(64, 8192)) };
        if self.session.preview_size != p {
            self.session.preview_size = p;
            self.session.dirty = true;
        }
    }

    /// Run an engine command, reporting errors as toasts. Returns the result on success.
    pub fn run(&mut self, id: &str, params: Value) -> Option<Value> {
        match materialcraft_engine::execute(&mut self.session, id, &params) {
            Ok(v) => Some(v),
            Err(e) => {
                self.toast(e.to_string(), true);
                None
            }
        }
    }

    pub fn toast(&mut self, text: impl Into<String>, error: bool) {
        let text = text.into();
        self.status = text.clone();
        self.session.log(text.clone());
        self.toasts.push(Toast { text, error, until: self.last_time + if error { 6.0 } else { 3.0 } });
    }

    /// Every `prefs.autosave_minutes`, write a modified package to the autosave folder.
    #[cfg(not(target_arch = "wasm32"))]
    fn autosave(&mut self, now: f64) {
        let period = self.ui.prefs.autosave_minutes as f64 * 60.0;
        if period <= 0.0 || !self.session.modified {
            self.next_autosave = now + period;
            return;
        }
        if now < self.next_autosave {
            return;
        }
        self.next_autosave = now + period;
        let dir = user_dir("autosave");
        let path = dir.join(format!("{}.mcraft", materialcraft_engine::formats::safe_file_name(&self.session.pkg.name)));
        let pkg = self.session.pkg.clone();
        let spawned = std::thread::Builder::new().name("materialcraft-autosave".into()).spawn(move || {
            let result = std::fs::create_dir_all(&dir)
                .map_err(|e| e.to_string())
                .and_then(|_| materialcraft_engine::formats::save_package(&pkg).map_err(|e| e.to_string()))
                .and_then(|bytes| materialcraft_engine::formats::write_atomic(&path, &bytes).map_err(|e| e.to_string()));
            match result {
                Ok(()) => log::info!("autosaved {}", path.display()),
                Err(e) => log::warn!("autosave to {} failed: {e}", path.display()),
            }
        });
        if let Err(e) = spawned {
            log::warn!("could not start autosave: {e}");
        }
    }
}

impl eframe::App for MaterialCraftApp {
    fn auto_save_interval(&self) -> std::time::Duration {
        std::time::Duration::from_secs(if cfg!(target_arch = "wasm32") { 5 } else { 30 })
    }

    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        eframe::set_value(storage, "ui", &self.ui);
    }

    fn raw_input_hook(&mut self, _ctx: &egui::Context, raw: &mut egui::RawInput) {
        control::feed_input(self, raw);
    }

    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.step(ctx);
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.draw(ui);
    }
}

impl MaterialCraftApp {
    /// Per-frame logic before drawing: styles, the control channel, cooking, shortcuts.
    pub fn step(&mut self, ctx: &egui::Context) {
        if !self.fonts_ready {
            theme::install(ctx);
            ctx.request_repaint();
            return;
        }
        let now = ctx.input(|i| i.time);
        let dt = (now - self.last_time) as f32;
        if dt > 0.0 {
            self.fps = self.fps * 0.9 + (1.0 / dt) * 0.1;
        }
        self.last_time = now;
        #[cfg(not(target_arch = "wasm32"))]
        if ctx.input(|input| input.viewport().visible().unwrap_or(true)) {
            if let Some(loaded) = self.palette_watcher.poll(ctx) {
                self.palette = Some(loaded.palette);
                self.palette_revision = self.palette_revision.wrapping_add(1);
            }
        }
        let style = (self.ui.prefs.brightness, self.ui.prefs.accent, self.palette_revision);
        if self.styled != Some(style) {
            theme::apply_with_palette(ctx, style.0, style.1, self.palette.as_ref());
            self.styled = Some(style);
        }
        let scale = self.ui.prefs.ui_scale.clamp(0.5, 3.0);
        if (ctx.zoom_factor() - scale).abs() > 1e-3 {
            ctx.set_zoom_factor(scale);
        }
        control::poll(self, ctx);
        web_files::poll(self);
        for f in ctx.input(|i| i.raw.dropped_files.clone()) {
            web_files::dropped(self, ctx, &f);
        }
        self.apply_prefs();
        cook::drive(self, ctx);
        #[cfg(not(target_arch = "wasm32"))]
        self.autosave(now);
        menus::shortcuts(self, ctx);
        self.toasts.retain(|t| t.until > now);
        if !self.input_queue.is_empty() {
            ctx.request_repaint();
        }
    }

    /// Draw the whole window into `ui`.
    pub fn draw(&mut self, ui: &mut egui::Ui) {
        if !self.fonts_ready {
            self.fonts_ready = true;
            return;
        }
        let ctx = ui.ctx().clone();
        let t0 = now_ms();
        menus::menu_bar(self, ui);
        toolbar::main_toolbar(self, ui);
        toolbar::status_bar(self, ui);
        egui::CentralPanel::default().frame(egui::Frame::NONE.fill(theme::Tokens::get(&ctx).chrome)).show(ui, |ui| docking::show(self, ui));
        windows::show(self, &ctx);
        function_editor::show(self, &ctx);
        toasts(self, &ctx);
        control::request_screenshots(self, &ctx);
        let dt = (now_ms() - t0) as f32;
        self.ui_ms = if self.ui_ms == 0.0 { dt } else { self.ui_ms * 0.9 + dt * 0.1 };
    }
}

/// `Documents/MaterialCraft/<sub>` in the user's home folder.
#[cfg(not(target_arch = "wasm32"))]
pub fn user_dir(sub: &str) -> std::path::PathBuf {
    let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_else(|_| ".".into());
    std::path::Path::new(&home).join("Documents").join("MaterialCraft").join(sub)
}

/// Milliseconds since the first call (0 on the web, where `std::time` is unavailable).
pub fn now_ms() -> f64 {
    materialcraft_engine::eval::now_ms()
}

fn toasts(app: &mut MaterialCraftApp, ctx: &egui::Context) {
    if app.toasts.is_empty() {
        return;
    }
    ctx.request_repaint_after(std::time::Duration::from_millis(250));
    let tk = theme::Tokens::get(ctx);
    egui::Area::new(egui::Id::unique("toasts")).anchor(egui::Align2::RIGHT_BOTTOM, egui::vec2(-16.0, -36.0)).show(ctx, |ui| {
        for t in &app.toasts {
            egui::Frame::NONE
                .fill(tk.panel)
                .stroke(egui::Stroke::new(1.0, if t.error { tk.danger } else { tk.accent }))
                .corner_radius(theme::CARD_RADIUS)
                .shadow(ui.visuals().popup_shadow)
                .inner_margin(egui::Margin::symmetric(10, 6))
                .show(ui, |ui| {
                    ui.set_max_width(380.0);
                    ui.label(egui::RichText::new(&t.text).color(tk.text_strong));
                });
            ui.add_space(4.0);
        }
    });
}
