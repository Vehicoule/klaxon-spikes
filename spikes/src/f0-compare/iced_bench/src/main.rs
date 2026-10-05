// f0-iced : bench iced 0.13 (canvas) — corpus fidèle, mesure draw() par frame.
use iced::widget::canvas::{self, Canvas, Fill, Frame, Path, Stroke, Text};
use iced::mouse;
use iced::{Element, Length, Point, Rectangle, Theme, Color, Vector, Subscription};
use std::time::{Duration, Instant};
use std::sync::Mutex;

static TIMES: Mutex<Vec<f64>> = Mutex::new(Vec::new());

struct App { scene: usize, frames: u32 }

#[derive(Debug, Clone)]
enum Msg { Tick }

impl App {
    fn update(&mut self, m: Msg) -> iced::Task<Msg> {
        match m { Msg::Tick => {
            self.frames += 1;
            if self.frames >= 120 {
                let ts = TIMES.lock().unwrap();
                let avg = ts.iter().sum::<f64>() / ts.len().max(1) as f64;
                let first = ts.first().copied().unwrap_or(0.0);
                let json = format!(
                    "{{\"tool\":\"iced-0.13\",\"backend\":\"auto\",\"scene\":\"s{}\",\"draw_ms_avg\":{:.3},\"draw_ms_first\":{:.3},\"frames\":{}}}",
                    self.scene, avg, first, self.frames);
                std::fs::create_dir_all("out").ok();
                std::fs::write(format!("out/f0-iced-s{}.json", self.scene), &json).unwrap();
                println!("{} ", json);
                std::process::exit(0);
            }
        }}
        iced::Task::none()
    }
    fn view(&self) -> Element<'_, Msg> {
        Canvas::new(Bench { scene: self.scene }).width(Length::Fill).height(Length::Fill).into()
    }
    fn subscription(&self) -> Subscription<Msg> {
        iced::time::every(Duration::from_millis(16)).map(|_| Msg::Tick)
    }
}

struct Bench { scene: usize }

impl canvas::Program<Msg> for Bench {
    type State = ();
    fn draw(&self, _s: &(), r: &iced::Renderer, _t: &Theme, b: Rectangle, _c: mouse::Cursor)
        -> Vec<canvas::Geometry> {
        let t0 = Instant::now();
        let mut f = Frame::new(r, b.size());
        let (w, h) = (b.width.max(800.), b.height.max(600.));
        f.fill_rectangle(Point::ORIGIN, b.size(), Color::WHITE);
        match self.scene {
            1 => {
                for i in 0..200u32 {
                    let c = Color::from_rgba(((i*37)%255) as f32/255., ((i*91)%255) as f32/255., ((i*57)%255) as f32/255., 0.55);
                    let p = Point::new((i*13) as f32 % (w-60.), (i*29) as f32 % (h-40.));
                    match i % 3 {
                        0 => f.fill_rectangle(p, iced::Size::new(60.,40.), c),
                        1 => f.fill(&Path::circle(p + Vector::new(25.,25.), 25.), Fill::from(c)),
                        _ => f.fill(&Path::rounded_rectangle(p, iced::Size::new(70.,30.), iced::border::Radius::from(8.0)), Fill::from(c)),
                    }
                }
            }
            2 => {
                for i in 0..20 {
                    f.fill_text(Text {
                        content: "Titre — évaluation Klaxon f0 bench §éçà€ 0123456789".into(),
                        position: Point::new(40., 40. + i as f32 * 22.),
                        color: Color::from_rgb(0.1,0.1,0.2),
                        size: if i%5==0 { 20.into() } else { 14.into() },
                        ..Text::default()
                    });
                }
            }
            3 => { // pseudo-blur : anneaux translucides (canvas n'a pas de blur natif)
                for i in 0..8u32 {
                    let cx = 110.+i as f32*90.; let cy = 190.+i as f32*45.;
                    for r in (0..70u32).rev().step_by(6) {
                        f.fill(&Path::circle(Point::new(cx,cy), r as f32),
                            Fill::from(Color::from_rgba(0.2+i as f32*0.05,0.35,0.85,0.05)));
                    }
                }
            }
            6 => {
                for i in 0..100u32 {
                    let p = Path::new(|b| {
                        b.move_to(Point::new((i*7) as f32 % w, h-60.));
                        b.bezier_curve_to(Point::new(60.+i as f32*5.,80.+i as f32*2.),
                            Point::new(320.-i as f32,40.+i as f32*4.), Point::new(700.,(300.+i as f32*6.)%(h-20.)));
                    });
                    f.stroke(&p, Stroke::default().with_color(Color::from_rgba(0.08,0.16,0.63,0.8)).with_width(2.));
                }
            }
            _ => {
                for i in 0..10u32 {
                    f.with_save(|f| { f.translate(Vector::new(20.+i as f32*10.,10.+i as f32*8.));
                        f.fill_rectangle(Point::new(60.+i as f32*40.,60.+i as f32*30.),
                            iced::Size::new(400.-i as f32*20.,260.-i as f32*12.),
                            Color::from_rgba(0.15+i as f32*0.08,0.7-i as f32*0.04,0.47,0.43)); });
                }
                for i in 0..20u32 {
                    f.fill(&Path::circle(Point::new(40.+i as f32*30.,40.+i as f32*22.),40.),
                        Fill::from(Color::from_rgba(0.9,0.5,0.2,0.6)));
                }
            }
        }
        TIMES.lock().unwrap().push(t0.elapsed().as_secs_f64()*1000.0);
        vec![f.into_geometry()]
    }
}

fn main() -> iced::Result {
    let scene: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1);
    iced::application("f0-iced", App::update, App::view)
        .subscription(App::subscription)
        .window_size((800., 600.))
        .run_with(move || (App { scene, frames: 0 }, iced::Task::none()))
}
