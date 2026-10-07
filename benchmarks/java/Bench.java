import com.lmax.disruptor.BusySpinWaitStrategy;
import com.lmax.disruptor.EventHandler;
import com.lmax.disruptor.EventTranslator;
import com.lmax.disruptor.RingBuffer;
import com.lmax.disruptor.dsl.Disruptor;
import com.lmax.disruptor.dsl.ProducerType;
import com.sun.management.ThreadMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.GarbageCollectorMXBean;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public final class Bench {
    static { System.loadLibrary("benchplatform"); }
    static native void pin(int cpu);
    static native long cpu();
    static native long rss();
    static int producers, consumers, capacity, words;
    static long warm, count, rate, start, eventBase;
    static boolean check;
    static int[] cpus;
    static volatile int phase;
    static volatile boolean slowEntered, slowRelease;
    static final AtomicInteger ready = new AtomicInteger();
    static final AtomicInteger producerDone = new AtomicInteger();
    static final AtomicLong attempted = new AtomicLong();
    static final AtomicLong published = new AtomicLong();

    static final class Event {
        final long[] data = new long[words];
    }
    static final class Handler implements EventHandler<Event> {
        final int cid;
        final long[] next = new long[producers];
        final long[] histogram = new long[rate > 0 ? 65536 : 0];
        final long[] trace = new long[check ? Math.toIntExact(warm + count) : 0];
        long seen, sum, hash, end, cpuEnd;
        volatile long done;
        Handler(int cid) {
            this.cid = cid;
            for (int p = 0; p < producers; p++) next[p] = p;
        }
        public void onEvent(Event event, long sequence, boolean endOfBatch) {
            if (seen == 0) pin(cpus[producers + cid]);
            if (check && cid == consumers - 1 && seen == warm) {
                slowEntered = true;
                while (!slowRelease) Thread.onSpinWait();
            }
            long id = event.data[0];
            int pid = (int)(id % producers);
            require(id == next[pid], "loss, duplicate, or producer reordering");
            next[pid] += producers;
            for (long word : event.data) sum += word;
            hash = hash * 31 + id;
            if (check) trace[(int)seen] = id;
            if (rate > 0) {
                long scheduled = start + (id - eventBase) * 1_000_000_000L / rate;
                long latency = System.nanoTime() - scheduled;
                require(latency >= 0, "arrival before schedule");
                int shift = Math.max(0, 64 - Long.numberOfLeadingZeros(latency | 1) - 10);
                histogram[shift * 1024 + (int)(latency >>> shift)]++;
            }
            seen++;
            if (seen == warm) {
                Arrays.fill(histogram, 0);
                done = seen;
            }
            if (seen == warm + count) {
                end = System.nanoTime();
                cpuEnd = cpu();
                done = seen;
            }
        }
    }
    static final class Publisher implements Runnable, EventTranslator<Event> {
        final int pid;
        final RingBuffer<Event> ring;
        long id;
        Publisher(int pid, RingBuffer<Event> ring) { this.pid = pid; this.ring = ring; }
        public void translateTo(Event event, long sequence) {
            for (int j = 0; j < words; j++) event.data[j] = id + j;
        }
        public void run() {
            pin(cpus[pid]);
            ready.incrementAndGet();
            for (int round = 1; round <= 2; round++) {
                while (phase < round) Thread.onSpinWait();
                long first = round == 1 ? 0 : warm;
                long n = round == 1 ? warm : count;
                for (id = first + pid; id < first + n; id += producers) {
                    if (rate > 0) {
                        long scheduled = start + (id - first) * 1_000_000_000L / rate;
                        while (System.nanoTime() < scheduled) Thread.onSpinWait();
                    }
                    if (check && round == 2) attempted.incrementAndGet();
                    ring.publishEvent(this);
                    if (check && round == 2) published.incrementAndGet();
                }
                producerDone.incrementAndGet();
            }
            while (phase != 3) nap();
        }
    }
    static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    static void nap() {
        try { Thread.sleep(1); } catch (InterruptedException e) { throw new RuntimeException(e); }
    }
    static void waitDone(Handler[] handlers, long target, int produced) {
        while (producerDone.get() < produced) nap();
        for (Handler h : handlers) while (h.done < target) nap();
    }
    static long percentile(long[] hist, long n, int permille) {
        long rank = (n * permille + 999) / 1000;
        long total = 0;
        for (int b = 0; b < hist.length; b++) {
            total += hist[b];
            if (total >= rank) return (((long)(b % 1024) + 1) << (b / 1024)) - 1;
        }
        throw new AssertionError("missing latency samples");
    }
    static long gcCount(List<GarbageCollectorMXBean> beans) {
        long n = 0;
        for (GarbageCollectorMXBean bean : beans) n += Math.max(0, bean.getCollectionCount());
        return n;
    }
    static long gcMillis(List<GarbageCollectorMXBean> beans) {
        long n = 0;
        for (GarbageCollectorMXBean bean : beans) n += Math.max(0, bean.getCollectionTime());
        return n;
    }
    static long allocated(ThreadMXBean bean, long[] ids) {
        long total = 0;
        for (long n : bean.getThreadAllocatedBytes(ids)) {
            require(n >= 0, "allocation counters unavailable");
            total += n;
        }
        return total;
    }
    public static void main(String[] args) throws Exception {
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
            error.printStackTrace();
            System.exit(1);
        });
        // Exercise both phase transitions before the real sample, not only the hot loop.
        String[] prewarm = args.clone();
        int p = Integer.parseInt(args[0]);
        long n = Math.max(100_000, Integer.parseInt(args[2]) * 4L);
        n = ((n + p - 1) / p) * p;
        prewarm[4] = prewarm[5] = Long.toString(n);
        prewarm[7] = "0";
        sample(prewarm, false);
        sample(prewarm, false);
        sample(args, true);
    }
    static void sample(String[] args, boolean emit) throws Exception {
        phase = 0; slowEntered = false; slowRelease = false;
        ready.set(0); producerDone.set(0); attempted.set(0); published.set(0);
        eventBase = 0;
        producers = Integer.parseInt(args[0]); consumers = Integer.parseInt(args[1]);
        capacity = Integer.parseInt(args[2]); words = Integer.parseInt(args[3]) / 8;
        warm = Long.parseLong(args[4]); count = Long.parseLong(args[5]);
        rate = Long.parseLong(args[6]); check = Integer.parseInt(args[7]) != 0;
        cpus = Arrays.stream(args).skip(8).mapToInt(Integer::parseInt).toArray();
        require(cpus.length == producers + consumers, "wrong CPU count");
        List<Thread> workers = new ArrayList<>();
        Disruptor<Event> disruptor = new Disruptor<>(Event::new, capacity, runnable -> {
            Thread thread = new Thread(runnable);
            workers.add(thread);
            return thread;
        }, producers == 1 ? ProducerType.SINGLE : ProducerType.MULTI, new BusySpinWaitStrategy());
        Handler[] handlers = new Handler[consumers];
        for (int c = 0; c < consumers; c++) handlers[c] = new Handler(c);
        disruptor.handleEventsWith(handlers);
        RingBuffer<Event> ring = disruptor.start();
        for (int p = 0; p < producers; p++) {
            Thread thread = new Thread(new Publisher(p, ring));
            workers.add(thread);
            thread.start();
        }
        ThreadMXBean bean = (ThreadMXBean)ManagementFactory.getThreadMXBean();
        require(bean.isThreadAllocatedMemorySupported(), "allocation counters unsupported");
        bean.setThreadAllocatedMemoryEnabled(true);
        List<GarbageCollectorMXBean> gc = ManagementFactory.getGarbageCollectorMXBeans();
        var compilation = ManagementFactory.getCompilationMXBean();
        long[] ids = workers.stream().mapToLong(Thread::threadId).toArray();
        // Initialize management counters before warmup, not in the timed window.
        allocated(bean, ids); gcCount(gc); gcMillis(gc); compilation.getTotalCompilationTime();
        while (ready.get() < producers) nap();
        start = System.nanoTime();
        phase = 1;
        waitDone(handlers, warm, producers);
        long warmElapsed = System.nanoTime() - start;
        long heapUsed = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getUsed();
        long allocBefore = allocated(bean, ids);
        long gcBefore = gcCount(gc), gcTimeBefore = gcMillis(gc);
        long jitBefore = compilation.getTotalCompilationTime();
        long cpuStart = cpu();
        eventBase = warm;
        start = System.nanoTime();
        phase = 2;
        long blocked = 0;
        if (check) {
            while (!slowEntered) nap();
            for (int i = 0; i < 50; i++) nap();
            blocked = published.get();
            for (int i = 0; i < 20; i++) nap();
            require(blocked > 0 && blocked <= capacity + 1 && blocked < count, "no bounded backpressure");
            require(published.get() == blocked && attempted.get() > blocked, "no blocked producer");
            slowRelease = true;
        }
        waitDone(handlers, warm + count, 2 * producers);
        long steadyBytes = allocated(bean, ids) - allocBefore;
        long collections = gcCount(gc) - gcBefore, gcMs = gcMillis(gc) - gcTimeBefore;
        long jitMs = compilation.getTotalCompilationTime() - jitBefore;
        long peakRss = rss();
        long end = 0, cpuEnd = 0;
        for (Handler h : handlers) { end = Math.max(end, h.end); cpuEnd = Math.max(cpuEnd, h.cpuEnd); }
        phase = 3;
        disruptor.shutdown();
        for (Thread thread : workers) thread.join();
        long total = warm + count;
        long expected = words * (total * (total - 1) / 2) + total * (words * (words - 1) / 2);
        for (Handler h : handlers) {
            require(h.seen == total && h.sum == expected && h.hash == handlers[0].hash, "invalid delivery");
            if (check) require(Arrays.equals(h.trace, handlers[0].trace), "broadcast order mismatch");
        }
        StringBuilder json = new StringBuilder();
        json.append("{\"valid\":true,\"warm_elapsed_ns\":").append(warmElapsed)
            .append(",\"elapsed_ns\":").append(end - start)
            .append(",\"cpu_ns\":").append(cpuEnd - cpuStart)
            .append(",\"peak_rss_bytes\":").append(peakRss)
            .append(",\"heap_used_bytes\":").append(heapUsed)
            .append(",\"measurement_bytes\":").append(rate > 0 ? consumers * 65536L * 8 : 0)
            .append(",\"steady_allocated_bytes\":").append(steadyBytes)
            .append(",\"gc_count\":").append(collections).append(",\"gc_ms\":").append(gcMs)
            .append(",\"jit_ms\":").append(jitMs)
            .append(",\"blocked_publications\":").append(blocked).append(",\"consumers\":[");
        for (int c = 0; c < consumers; c++) {
            Handler h = handlers[c];
            if (c > 0) json.append(',');
            json.append("{\"count\":").append(h.seen)
                .append(",\"checksum\":").append(Long.toUnsignedString(h.sum))
                .append(",\"order_hash\":").append(Long.toUnsignedString(h.hash));
            if (rate > 0) {
                json.append(",\"samples\":").append(count)
                    .append(",\"p50_ns\":").append(percentile(h.histogram, count, 500))
                    .append(",\"p99_ns\":").append(percentile(h.histogram, count, 990))
                    .append(",\"p999_ns\":").append(percentile(h.histogram, count, 999));
            }
            json.append('}');
        }
        json.append("]}");
        if (emit) System.out.println(json);
    }
}
