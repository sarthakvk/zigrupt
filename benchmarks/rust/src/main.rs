use disruptor::{build_multi_producer, build_single_producer, BusySpin, Producer};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering::*};
use std::sync::{Arc, Mutex};
use std::thread;

extern "C" {
    /// Returns the current monotonic time in nanoseconds.
    fn bench_now() -> u64;
    /// Returns process CPU time in nanoseconds.
    fn bench_cpu() -> u64;
    /// Returns the process's peak resident memory in bytes.
    fn bench_rss() -> u64;
    /// Pins the calling thread to a CPU core.
    fn bench_pin(cpu: i32);
    /// Sleeps briefly while waiting for a benchmark phase to finish.
    fn bench_sleep();
}
/// Reads the platform's monotonic clock.
fn now() -> u64 {
    unsafe { bench_now() }
}
/// Reads process CPU time.
fn cpu() -> u64 {
    unsafe { bench_cpu() }
}
/// Sleeps briefly to avoid a busy wait between benchmark phases.
fn sleep() {
    unsafe { bench_sleep() }
}
/// Pins the calling thread to the selected CPU core.
fn pin(core: i32) {
    unsafe { bench_pin(core) }
}

/// Tracks allocation count and live bytes through the system allocator.
struct CountingAllocator;
static ALLOCS: AtomicU64 = AtomicU64::new(0);
static LIVE: AtomicU64 = AtomicU64::new(0);
unsafe impl GlobalAlloc for CountingAllocator {
    /// Allocates memory and records successful allocations.
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc(layout);
        if !ptr.is_null() {
            ALLOCS.fetch_add(1, Relaxed);
            LIVE.fetch_add(layout.size() as u64, Relaxed);
        }
        ptr
    }
    /// Deallocates memory and updates the live-byte count.
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size() as u64, Relaxed);
        System.dealloc(ptr, layout);
    }
}
#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

/// Command-line configuration for one benchmark run.
#[derive(Clone)]
struct Args {
    p: usize,
    c: usize,
    capacity: usize,
    warm: u64,
    count: u64,
    rate: u64,
    check: bool,
    cpus: Vec<i32>,
}
/// Cross-thread phase signals, counters, and consumer results.
struct Shared {
    args: Args,
    phase: AtomicUsize,
    ready: AtomicUsize,
    producers_done: AtomicUsize,
    warm_done: AtomicUsize,
    done: AtomicUsize,
    slow_entered: AtomicBool,
    slow_release: AtomicBool,
    attempted: AtomicU64,
    published: AtomicU64,
    start: AtomicU64,
    event_base: AtomicU64,
    results: Vec<Mutex<Option<State>>>,
}
/// One consumer's validation and measurement data.
#[repr(align(128))]
struct State {
    count: u64,
    sum: u64,
    hash: u64,
    next: Vec<u64>,
    histogram: Vec<u64>,
    trace: Vec<u64>,
    end: u64,
    cpu_end: u64,
}
impl State {
    /// Allocates the optional latency histogram and correctness trace.
    fn new(a: &Args) -> Self {
        Self {
            count: 0,
            sum: 0,
            hash: 0,
            next: (0..a.p as u64).collect(),
            histogram: vec![0; if a.rate > 0 { 65536 } else { 0 }],
            trace: vec![
                0;
                if a.check {
                    (a.warm + a.count) as usize
                } else {
                    0
                }
            ],
            end: 0,
            cpu_end: 0,
        }
    }
}
/// Creates a consumer callback that validates delivery and records results.
fn handler<const W: usize>(
    shared: Arc<Shared>,
    cid: usize,
) -> impl FnMut(&[u64; W], i64, bool) + Send {
    let mut state: Option<State> = Some(State::new(&shared.args));
    move |event: &[u64; W], _, _| {
        let a: &Args = &shared.args;
        let s: &mut State = state.as_mut().expect("extra delivery");
        if s.count == 0 {
            pin(a.cpus[a.p + cid]);
        }
        if a.check && cid == a.c - 1 && s.count == a.warm {
            // Hold the final consumer so publication must stop when the ring fills.
            shared.slow_entered.store(true, Release);
            while !shared.slow_release.load(Acquire) {
                std::hint::spin_loop();
            }
        }
        let id: u64 = event[0];
        let pid: usize = (id % a.p as u64) as usize;
        assert_eq!(id, s.next[pid], "loss, duplicate, or producer reordering");
        s.next[pid] += a.p as u64;
        for &word in event {
            s.sum = s.sum.wrapping_add(word);
        }
        s.hash = s.hash.wrapping_mul(31).wrapping_add(id);
        if a.check {
            s.trace[s.count as usize] = id;
        }
        if a.rate > 0 {
            let offset: u64 = id - shared.event_base.load(Relaxed);
            let scheduled: u64 = shared.start.load(Relaxed) + offset * 1_000_000_000 / a.rate;
            let latency: u64 = now() - scheduled;
            // Logarithmic buckets retain 1024 steps within each power-of-two range.
            let shift: u32 = (64 - (latency | 1).leading_zeros()).saturating_sub(10);
            s.histogram[shift as usize * 1024 + (latency >> shift) as usize] += 1;
        }
        s.count += 1;
        if s.count == a.warm {
            s.histogram.fill(0);
            shared.warm_done.fetch_add(1, Release);
        }
        if s.count == a.warm + a.count {
            s.end = now();
            s.cpu_end = cpu();
            *shared.results[cid].lock().unwrap() = state.take();
            shared.done.fetch_add(1, Release);
        }
    }
}
/// Converts a histogram rank to its bucket's upper latency bound.
fn percentile(hist: &[u64], n: u64, permille: u64) -> u64 {
    let rank: u64 = (n * permille + 999) / 1000;
    let mut total: u64 = 0;
    for (bucket, &v) in hist.iter().enumerate() {
        total += v;
        if total >= rank {
            return (((bucket % 1024 + 1) as u64) << (bucket / 1024)) - 1;
        }
    }
    panic!("missing latency samples");
}
/// Publishes this producer's interleaved event IDs in both benchmark phases.
fn publish<const W: usize, P: Producer<[u64; W]>>(mut producer: P, s: Arc<Shared>, pid: usize) {
    let a: &Args = &s.args;
    pin(a.cpus[pid]);
    s.ready.fetch_add(1, Release);
    for round in 1..=2 {
        // The acquire load also makes the phase's start time visible to producers.
        while s.phase.load(Acquire) < round {
            std::hint::spin_loop();
        }
        let first: u64 = if round == 1 { 0 } else { a.warm };
        let n: u64 = if round == 1 { a.warm } else { a.count };
        for id in ((first + pid as u64)..(first + n)).step_by(a.p) {
            if a.rate > 0 {
                let scheduled: u64 = s.start.load(Relaxed) + (id - first) * 1_000_000_000 / a.rate;
                while now() < scheduled {
                    std::hint::spin_loop();
                }
            }
            if a.check && round == 2 {
                s.attempted.fetch_add(1, Relaxed);
            }
            producer.publish(|event| {
                for (j, word) in event.iter_mut().enumerate() {
                    *word = id + j as u64;
                }
            });
            if a.check && round == 2 {
                s.published.fetch_add(1, Release);
            }
        }
        s.producers_done.fetch_add(1, Release);
    }
    // Dropping the last producer joins the library's consumers, outside measurement.
    while s.phase.load(Acquire) != 3 {
        sleep();
    }
}
/// Runs warmup and measurement, validates consumers, and prints JSON results.
fn measure<const W: usize, P: Producer<[u64; W]> + Send + 'static>(
    handles: Vec<P>,
    s: Arc<Shared>,
) {
    let a: &Args = &s.args;
    let threads: Vec<_> = handles
        .into_iter()
        .enumerate()
        .map(|(pid, p)| {
            let s = Arc::clone(&s);
            thread::spawn(move || publish(p, s, pid))
        })
        .collect();
    while s.ready.load(Acquire) < a.p {
        sleep();
    }
    s.start.store(now(), Relaxed);
    s.phase.store(1, Release);
    while s.warm_done.load(Acquire) < a.c || s.producers_done.load(Acquire) < a.p {
        sleep();
    }
    let warm_elapsed: u64 = now() - s.start.load(Relaxed);
    let live: u64 = LIVE.load(Relaxed);
    let allocations: u64 = ALLOCS.load(Relaxed);
    let cpu_start: u64 = cpu();
    let start: u64 = now();
    s.event_base.store(a.warm, Relaxed);
    s.start.store(start, Relaxed);
    // Release publishes the measurement clock and event base to all workers.
    s.phase.store(2, Release);
    let mut blocked: u64 = 0;
    if a.check {
        // Confirm publication stalls while the slow consumer holds its slot.
        while !s.slow_entered.load(Acquire) {
            sleep();
        }
        for _ in 0..50 {
            sleep();
        }
        blocked = s.published.load(Acquire);
        for _ in 0..20 {
            sleep();
        }
        assert!(blocked > 0 && blocked <= a.capacity as u64 + 1 && blocked < a.count);
        assert_eq!(blocked, s.published.load(Acquire), "no backpressure");
        assert!(s.attempted.load(Relaxed) > blocked);
        s.slow_release.store(true, Release);
    }
    while s.done.load(Acquire) < a.c || s.producers_done.load(Acquire) < 2 * a.p {
        sleep();
    }
    let steady_allocations: u64 = ALLOCS.load(Relaxed) - allocations;
    let rss: u64 = unsafe { bench_rss() };
    s.phase.store(3, Release);
    for t in threads {
        t.join().unwrap();
    }
    let states: Vec<State> = s
        .results
        .iter()
        .map(|r| r.lock().unwrap().take().unwrap())
        .collect();
    let end: u64 = states.iter().map(|r| r.end).max().unwrap();
    let cpu_end: u64 = states.iter().map(|r| r.cpu_end).max().unwrap();
    let total: u64 = a.warm + a.count;
    let expected: u64 = (W as u64)
        .wrapping_mul(total * (total - 1) / 2)
        .wrapping_add(total * (W * (W - 1) / 2) as u64);
    for r in &states {
        assert_eq!(r.count, total);
        assert_eq!(r.sum, expected);
        assert_eq!(r.hash, states[0].hash);
        if a.check {
            assert_eq!(r.trace, states[0].trace);
        }
    }
    print!("{{\"warm_elapsed_ns\":{},", warm_elapsed);
    print!("\"valid\":true,\"elapsed_ns\":{},\"cpu_ns\":{},\"peak_rss_bytes\":{},\"allocator_live_bytes\":{},\"measurement_bytes\":{},\"steady_allocations\":{},\"blocked_publications\":{},\"consumers\":[",
        end - start, cpu_end - cpu_start, rss, live, if a.rate > 0 { a.c * 65536 * 8 } else { 0 }, steady_allocations, blocked);
    for (cid, r) in states.iter().enumerate() {
        if cid > 0 {
            print!(",");
        }
        print!(
            "{{\"count\":{},\"checksum\":{},\"order_hash\":{}",
            r.count, r.sum, r.hash
        );
        if a.rate > 0 {
            print!(
                ",\"samples\":{},\"p50_ns\":{},\"p99_ns\":{},\"p999_ns\":{}",
                a.count,
                percentile(&r.histogram, a.count, 500),
                percentile(&r.histogram, a.count, 990),
                percentile(&r.histogram, a.count, 999)
            );
        }
        print!("}}");
    }
    println!("]}}");
}
/// Builds the requested producer and consumer topology.
fn run<const W: usize>(a: Args) {
    let s: Arc<Shared> = Arc::new(Shared {
        results: (0..a.c).map(|_| Mutex::new(None)).collect(),
        args: a,
        phase: AtomicUsize::new(0),
        ready: AtomicUsize::new(0),
        producers_done: AtomicUsize::new(0),
        warm_done: AtomicUsize::new(0),
        done: AtomicUsize::new(0),
        slow_entered: AtomicBool::new(false),
        slow_release: AtomicBool::new(false),
        attempted: AtomicU64::new(0),
        published: AtomicU64::new(0),
        start: AtomicU64::new(0),
        event_base: AtomicU64::new(0),
    });
    let factory = || [0_u64; W];
    if s.args.p == 1 {
        let builder = build_single_producer(s.args.capacity, factory, BusySpin)
            .handle_events_with(handler(Arc::clone(&s), 0));
        if s.args.c == 1 {
            measure(vec![builder.build()], s);
        } else {
            let p = builder
                .handle_events_with(handler(Arc::clone(&s), 1))
                .handle_events_with(handler(Arc::clone(&s), 2))
                .build();
            measure(vec![p], s);
        }
    } else {
        let builder = build_multi_producer(s.args.capacity, factory, BusySpin)
            .handle_events_with(handler(Arc::clone(&s), 0));
        if s.args.c == 1 {
            let p = builder.build();
            let mut handles: Vec<_> = (1..s.args.p).map(|_| p.clone()).collect();
            handles.push(p);
            measure(handles, s);
        } else {
            let mut builder = builder.handle_events_with(handler(Arc::clone(&s), 1));
            if s.args.c == 3 {
                builder = builder.handle_events_with(handler(Arc::clone(&s), 2));
            }
            let p = builder.build();
            let mut handles: Vec<_> = (1..s.args.p).map(|_| p.clone()).collect();
            handles.push(p);
            measure(handles, s);
        }
    }
}
/// Parses benchmark arguments and selects the event payload width.
fn main() {
    let n: Vec<u64> = std::env::args()
        .skip(1)
        .map(|v| v.parse().unwrap())
        .collect();
    assert!(n.len() >= 10);
    let a: Args = Args {
        p: n[0] as usize,
        c: n[1] as usize,
        capacity: n[2] as usize,
        warm: n[4],
        count: n[5],
        rate: n[6],
        check: n[7] != 0,
        cpus: n[8..].iter().map(|&v| v as i32).collect(),
    };
    assert_eq!(a.cpus.len(), a.p + a.c);
    assert!(matches!(
        (a.p, a.c),
        (1, 1) | (2, 1) | (2, 2) | (4, 1) | (1, 3) | (3, 3)
    ));
    match n[3] {
        8 => run::<1>(a),
        64 => run::<8>(a),
        _ => panic!("payload must be 8 or 64"),
    }
}
