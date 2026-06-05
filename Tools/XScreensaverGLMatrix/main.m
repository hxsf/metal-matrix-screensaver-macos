#define GL_SILENCE_DEPRECATION 1
#import <AppKit/AppKit.h>
#import <OpenGL/gl.h>
#import <OpenGL/glu.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../../Resources/matrix3.xpm"

#define CHAR_COLS 16
#define CHAR_ROWS 13
#define GRID_SIZE 70
#define GRID_DEPTH 35
#define WAVE_SIZE 22
#define SPLASH_RATIO 0.7

typedef BOOL Bool;

static const int matrix_encoding[] = {
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    160, 161, 162, 163, 164, 165, 166, 167,
    168, 169, 170, 171, 172, 173, 174, 175
};

static const struct { GLfloat x, y; } nice_views[] = {
    { 0, 0 }, { 0, -20 }, { 0, 20 }, { 25, 0 }, { -25, 0 },
    { 25, 20 }, { -25, 20 }, { 25, -20 }, { -25, -20 },
    { 10, 0 }, { -10, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 },
    { 0, 0 }, { 0, 0 },
};

typedef struct {
    GLfloat x, y, z;
    GLfloat dx, dy, dz;
    Bool erasing_p;
    int spinner_glyph;
    GLfloat spinner_y;
    GLfloat spinner_speed;
    int glyphs[GRID_SIZE];
    Bool highlight[GRID_SIZE];
    int spin_speed;
    int spin_tick;
    int wave_position;
    int wave_speed;
    int wave_tick;
} strip;

typedef struct {
    GLuint texture;
    int nstrips;
    strip *strips;
    const int *glyph_map;
    int nglyphs;
    GLfloat tex_char_width;
    GLfloat tex_char_height;
    int last_view;
    int target_view;
    GLfloat view_x;
    GLfloat view_y;
    int view_steps;
    int view_tick;
    Bool auto_tracking_p;
    int track_tick;
    int real_char_rows;
    GLfloat brightness_ramp[WAVE_SIZE];
} matrix_configuration;

static matrix_configuration matrix_config;
static GLfloat speed = 1.0;
static GLfloat density = 100.0;
static Bool do_fog = YES;
static Bool do_waves = YES;
static Bool do_rotate = YES;
static Bool do_texture = YES;

static GLfloat frandf(GLfloat n) {
    return ((GLfloat)random() / (GLfloat)RAND_MAX) * n;
}

static GLfloat bellrand(GLfloat n) {
    return (frandf(n) + frandf(n) + frandf(n)) / 3.0f;
}

static void parseHexColor(const char *text, unsigned char *r, unsigned char *g, unsigned char *b, unsigned char *a) {
    if (!text || !strcmp(text, "None")) {
        *r = *g = *b = *a = 0;
        return;
    }
    unsigned int rv = 0, gv = 0, bv = 0;
    sscanf(text, "#%02x%02x%02x", &rv, &gv, &bv);
    *r = (unsigned char)rv;
    *g = (unsigned char)gv;
    *b = (unsigned char)bv;
    *a = 255;
}

static unsigned char *load_matrix_xpm(int *outWidth, int *outHeight) {
    int width = 0, height = 0, colors = 0, cpp = 0;
    sscanf(matrix3_xpm[0], "%d %d %d %d", &width, &height, &colors, &cpp);
    if (width <= 0 || height <= 0 || cpp != 1) {
        fprintf(stderr, "Unsupported XPM header: %s\n", matrix3_xpm[0]);
        exit(1);
    }

    unsigned char table[256][4];
    memset(table, 0, sizeof(table));
    for (int i = 0; i < colors; i++) {
        const char *line = matrix3_xpm[1 + i];
        unsigned char key = (unsigned char)line[0];
        const char *color = strstr(line, " c ");
        if (!color) color = strstr(line, "\tc ");
        color = color ? color + 3 : "None";
        while (*color == ' ' || *color == '\t') color++;
        parseHexColor(color, &table[key][0], &table[key][1], &table[key][2], &table[key][3]);
    }

    unsigned char *pixels = calloc((size_t)width * (size_t)height * 4, 1);
    if (!pixels) exit(1);
    for (int y = 0; y < height; y++) {
        const char *row = matrix3_xpm[1 + colors + y];
        for (int x = 0; x < width; x++) {
            unsigned char key = (unsigned char)row[x];
            unsigned char *p = pixels + (((size_t)y * width + x) * 4);
            p[0] = table[key][0];
            p[1] = table[key][1];
            p[2] = table[key][2];
            p[3] = table[key][3];
        }
    }

    *outWidth = width;
    *outHeight = height;
    return pixels;
}

static void spank_image(unsigned char *pixels, int width, int *height, int *realRows) {
    int ch = *height / CHAR_ROWS;
    int cut = 2;
    int rowBytes = width * 4;
    int L = rowBytes * ch;
    memmove(pixels + (L * cut), pixels, (size_t)L);
    memmove(pixels, pixels + (L * cut), (size_t)L * CHAR_ROWS - (size_t)L * cut);
    memset(pixels + (size_t)L * (CHAR_ROWS - cut), 0, (size_t)L * cut);
    *height -= cut * ch;
    *realRows -= cut;
}

static void load_textures(void) {
    int origW = 0, origH = 0;
    unsigned char *pixels = load_matrix_xpm(&origW, &origH);
    int width = origW;
    int height = origH;
    matrix_config.real_char_rows = CHAR_ROWS;
    spank_image(pixels, width, &height, &matrix_config.real_char_rows);

    int paddedHeight = (height < 512 ? 512 : 1024);
    unsigned char *padded = calloc((size_t)width * (size_t)paddedHeight * 4, 1);
    if (!padded) exit(1);
    for (int y = 0; y < height; y++) {
        memcpy(padded + (size_t)y * width * 4,
               pixels + (size_t)y * width * 4,
               (size_t)width * 4);
    }
    free(pixels);
    height = paddedHeight;

    int cw = origW / CHAR_COLS;
    int ch = origH / CHAR_ROWS;
    matrix_config.tex_char_width = (GLfloat)cw / (GLfloat)width;
    matrix_config.tex_char_height = (GLfloat)ch / (GLfloat)height;

    for (int y = 0; y < height; y++) {
        for (int col = 0; col < CHAR_COLS; col++) {
            int base = col * cw;
            for (int x = 0; x < cw / 2; x++) {
                unsigned char *a = padded + ((size_t)y * width + base + x) * 4;
                unsigned char *b = padded + ((size_t)y * width + base + (cw - x - 1)) * 4;
                unsigned char tmp[4];
                memcpy(tmp, a, 4);
                memcpy(a, b, 4);
                memcpy(b, tmp, 4);
            }
        }
    }

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            unsigned char *p = padded + ((size_t)y * width + x) * 4;
            unsigned char alpha = p[1];
            p[1] = 255;
            p[3] = alpha;
        }
    }

    glGenTextures(1, &matrix_config.texture);
    glBindTexture(GL_TEXTURE_2D, matrix_config.texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, padded);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
    free(padded);
}

static void reset_strip(strip *s) {
    memset(s, 0, sizeof(*s));
    s->x = frandf(GRID_SIZE) - (GRID_SIZE / 2);
    s->y = (GRID_SIZE / 2) + bellrand(0.5);
    s->z = (GRID_DEPTH * 0.2) - frandf(GRID_DEPTH * 0.7);
    s->dz = bellrand(0.02) * speed;
    s->spinner_speed = bellrand(0.3) * speed;
    s->spin_speed = (int)bellrand(2.0 / speed) + 1;
    s->wave_speed = (int)bellrand(3.0 / speed) + 1;

    for (int i = 0; i < GRID_SIZE; i++) {
        int draw_p = random() % 7;
        int spin_p = (draw_p && !(random() % 20));
        int g = draw_p ? matrix_config.glyph_map[random() % matrix_config.nglyphs] + 1 : 0;
        if (spin_p) g = -g;
        s->glyphs[i] = g;
        s->highlight[i] = NO;
    }
    s->spinner_glyph = -(matrix_config.glyph_map[random() % matrix_config.nglyphs] + 1);
}

static void tick_strip(strip *s) {
    s->x += s->dx;
    s->y += s->dy;
    s->z += s->dz;
    if (s->z > GRID_DEPTH * SPLASH_RATIO) {
        reset_strip(s);
        return;
    }

    s->spinner_y += s->spinner_speed;
    if (s->spinner_y >= GRID_SIZE) {
        if (s->erasing_p) {
            reset_strip(s);
            return;
        } else {
            s->erasing_p = YES;
            s->spinner_y = 0;
            s->spinner_speed /= 2;
        }
    }

    if (++s->spin_tick > s->spin_speed) {
        s->spin_tick = 0;
        s->spinner_glyph = -(matrix_config.glyph_map[random() % matrix_config.nglyphs] + 1);
        for (int i = 0; i < GRID_SIZE; i++) {
            if (s->glyphs[i] < 0) {
                s->glyphs[i] = -(matrix_config.glyph_map[random() % matrix_config.nglyphs] + 1);
                if (!(random() % 800)) s->glyphs[i] = -s->glyphs[i];
            }
        }
    }

    if (++s->wave_tick > s->wave_speed) {
        s->wave_tick = 0;
        if (++s->wave_position >= WAVE_SIZE) s->wave_position = 0;
    }
}

static void draw_glyph(int glyph, Bool highlight, GLfloat x, GLfloat y, GLfloat z, GLfloat brightness) {
    GLfloat w = matrix_config.tex_char_width;
    GLfloat h = matrix_config.tex_char_height;
    GLfloat cx = 0, cy = 0;
    Bool spinner_p = glyph < 0;
    if (glyph == 0) return;
    if (glyph < 0) glyph = -glyph;
    if (spinner_p) brightness *= 1.5;

    int ccx = (glyph - 1) % CHAR_COLS;
    int ccy = (glyph - 1) / CHAR_COLS;
    cx = ccx * w;
    cy = (matrix_config.real_char_rows - ccy - 1) * h;
    if (do_fog) {
        GLfloat depth = (z / GRID_DEPTH) + 0.5;
        depth = 0.2 + (depth * 0.8);
        brightness *= depth;
    }
    if (highlight) brightness *= 2;
    GLfloat a = brightness;
    if (z > GRID_DEPTH / 2) {
        GLfloat ratio = ((z - GRID_DEPTH / 2) / ((GRID_DEPTH * SPLASH_RATIO) - GRID_DEPTH / 2));
        int i = ratio * WAVE_SIZE;
        if (i < 0) i = 0;
        else if (i >= WAVE_SIZE) i = WAVE_SIZE - 1;
        a *= matrix_config.brightness_ramp[i];
    }

    glColor4f(1, 1, 1, a);
    glBegin(GL_QUADS);
    glNormal3f(0, 0, 1);
    glTexCoord2f(cx, cy);       glVertex3f(x, y, z);
    glTexCoord2f(cx + w, cy);   glVertex3f(x + 1, y, z);
    glTexCoord2f(cx + w, cy+h); glVertex3f(x + 1, y + 1, z);
    glTexCoord2f(cx, cy+h);     glVertex3f(x, y + 1, z);
    glEnd();
}

static void draw_strip(strip *s) {
    for (int i = 0; i < GRID_SIZE; i++) {
        int g = s->glyphs[i];
        Bool below_p = s->spinner_y >= i;
        if (s->erasing_p) below_p = !below_p;
        if (g && below_p) {
            GLfloat brightness = 1.0;
            if (do_waves) {
                int j = WAVE_SIZE - ((i + (GRID_SIZE - s->wave_position)) % WAVE_SIZE);
                brightness = matrix_config.brightness_ramp[j];
            }
            draw_glyph(g, s->highlight[i], s->x, s->y - i, s->z, brightness);
        }
    }
    if (!s->erasing_p) {
        draw_glyph(s->spinner_glyph, NO, s->x, s->y - s->spinner_y, s->z, 1.0);
    }
}

static int cmp_strips(const void *aa, const void *bb) {
    const strip *a = *(const strip **)aa;
    const strip *b = *(const strip **)bb;
    return (int)(a->z * 10000) - (int)(b->z * 10000);
}

static void auto_track_init(void) {
    matrix_config.last_view = 0;
    matrix_config.target_view = 0;
    matrix_config.view_x = nice_views[0].x;
    matrix_config.view_y = nice_views[0].y;
    matrix_config.view_steps = 100;
    matrix_config.view_tick = 0;
    matrix_config.auto_tracking_p = NO;
}

static void auto_track(void) {
    if (!do_rotate) return;
    if (!matrix_config.auto_tracking_p) {
        if (++matrix_config.track_tick < 20 / speed) return;
        matrix_config.track_tick = 0;
        if (!(random() % 20)) matrix_config.auto_tracking_p = YES;
        else return;
    }

    GLfloat ox = nice_views[matrix_config.last_view].x;
    GLfloat oy = nice_views[matrix_config.last_view].y;
    GLfloat tx = nice_views[matrix_config.target_view].x;
    GLfloat ty = nice_views[matrix_config.target_view].y;
    GLfloat th = sin((M_PI / 2) * (double)matrix_config.view_tick / matrix_config.view_steps);
    matrix_config.view_x = ox + ((tx - ox) * th);
    matrix_config.view_y = oy + ((ty - oy) * th);
    matrix_config.view_tick++;
    if (matrix_config.view_tick >= matrix_config.view_steps) {
        matrix_config.view_tick = 0;
        matrix_config.view_steps = 350.0 / speed;
        matrix_config.last_view = matrix_config.target_view;
        matrix_config.target_view = (random() % ((int)(sizeof(nice_views) / sizeof(nice_views[0])) - 1)) + 1;
        matrix_config.auto_tracking_p = NO;
    }
}

static void reshape_matrix(int width, int height) {
    GLfloat h = (GLfloat)height / (GLfloat)width;
    glViewport(0, 0, width, height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluPerspective(80.0, 1 / h, 1.0, 100);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    gluLookAt(0.0, 0.0, 25.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0);
    glClear(GL_COLOR_BUFFER_BIT);
}

static void init_matrix(int width, int height) {
    memset(&matrix_config, 0, sizeof(matrix_config));
    matrix_config.glyph_map = matrix_encoding;
    matrix_config.nglyphs = (int)(sizeof(matrix_encoding) / sizeof(matrix_encoding[0]));
    reshape_matrix(width, height);

    glShadeModel(GL_SMOOTH);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glEnable(GL_NORMALIZE);
    glClearColor(0, 0, 0, 1);

    if (do_texture) {
        load_textures();
        glEnable(GL_TEXTURE_2D);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE);
    }

    matrix_config.nstrips = (int)(density * 2.2);
    if (matrix_config.nstrips < 1) matrix_config.nstrips = 1;
    else if (matrix_config.nstrips > 2000) matrix_config.nstrips = 2000;
    matrix_config.strips = calloc((size_t)matrix_config.nstrips, sizeof(strip));

    for (int i = 0; i < matrix_config.nstrips; i++) {
        strip *s = &matrix_config.strips[i];
        reset_strip(s);
        s->erasing_p = YES;
        s->spinner_y = frandf(GRID_SIZE);
        memset(s->glyphs, 0, sizeof(s->glyphs));
    }

    for (int i = 0; i < WAVE_SIZE; i++) {
        GLfloat j = ((WAVE_SIZE - i) / (GLfloat)(WAVE_SIZE - 1));
        j *= M_PI / 2;
        j = sin(j);
        matrix_config.brightness_ramp[i] = 0.2 + (j * 0.8);
    }
    auto_track_init();
}

static void draw_matrix(void) {
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glPushMatrix();
    if (do_rotate) {
        glRotatef(matrix_config.view_x, 1, 0, 0);
        glRotatef(matrix_config.view_y, 0, 1, 0);
    }

    strip **sorted = malloc((size_t)matrix_config.nstrips * sizeof(*sorted));
    for (int i = 0; i < matrix_config.nstrips; i++) sorted[i] = &matrix_config.strips[i];
    qsort(sorted, (size_t)matrix_config.nstrips, sizeof(*sorted), cmp_strips);
    for (int i = 0; i < matrix_config.nstrips; i++) {
        tick_strip(sorted[i]);
        draw_strip(sorted[i]);
    }
    free(sorted);
    auto_track();
    glPopMatrix();
    glFlush();
}

@interface MatrixOpenGLView : NSOpenGLView
@property(nonatomic) BOOL initializedMatrix;
@end

@implementation MatrixOpenGLView

- (instancetype)initWithFrame:(NSRect)frameRect {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADepthSize, 16,
        0
    };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    self = [super initWithFrame:frameRect pixelFormat:format];
    return self;
}

- (void)prepareOpenGL {
    [super prepareOpenGL];
    GLint swapInterval = 1;
    [[self openGLContext] setValues:&swapInterval forParameter:NSOpenGLCPSwapInterval];
}

- (void)reshape {
    [super reshape];
    [[self openGLContext] makeCurrentContext];
    NSRect bounds = [self bounds];
    reshape_matrix((int)bounds.size.width, (int)bounds.size.height);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[self openGLContext] makeCurrentContext];
    if (!self.initializedMatrix) {
        NSRect bounds = [self bounds];
        init_matrix((int)bounds.size.width, (int)bounds.size.height);
        self.initializedMatrix = YES;
    }
    draw_matrix();
    [[self openGLContext] flushBuffer];
}

@end

@interface XScreenSaverPreviewController : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) MatrixOpenGLView *glView;
@property(nonatomic, copy) NSString *outputPath;
@property(nonatomic) NSTimeInterval startedAt;
@property(nonatomic) NSTimeInterval captureDelay;
@end

@implementation XScreenSaverPreviewController

- (instancetype)initWithOutputPath:(NSString *)outputPath captureDelay:(NSTimeInterval)captureDelay {
    self = [super init];
    if (self) {
        _outputPath = [outputPath copy];
        _captureDelay = captureDelay;
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    srandom(0x5c11);
    NSRect frame = NSMakeRect(0, 0, 632, 408);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.backgroundColor = [NSColor blackColor];
    [self.window center];
    self.glView = [[MatrixOpenGLView alloc] initWithFrame:frame];
    self.window.contentView = self.glView;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];
    [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                     target:self
                                   selector:@selector(tick:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    [self.glView setNeedsDisplay:YES];
    [self.glView displayIfNeeded];
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.startedAt;
    if (elapsed < self.captureDelay) return;
    [timer invalidate];
    [self saveWindowImage];
    [NSApp terminate:self];
}

- (void)saveWindowImage {
    [[self.glView openGLContext] makeCurrentContext];
    NSRect bounds = [self.glView bounds];
    int width = (int)bounds.size.width;
    int height = (int)bounds.size.height;
    if (width <= 0 || height <= 0) {
        NSLog(@"Invalid GL view size");
        return;
    }
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)width * (NSUInteger)height * 4];
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.mutableBytes);

    NSMutableData *flipped = [NSMutableData dataWithLength:pixels.length];
    const unsigned char *src = pixels.bytes;
    unsigned char *dst = flipped.mutableBytes;
    size_t rowBytes = (size_t)width * 4;
    for (int y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * rowBytes,
               src + (size_t)(height - y - 1) * rowBytes,
               rowBytes);
    }

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:width
                      pixelsHigh:height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:(NSInteger)rowBytes
                    bitsPerPixel:32];
    memcpy(bitmap.bitmapData, flipped.bytes, flipped.length);
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    BOOL ok = [png writeToFile:self.outputPath atomically:YES];
    NSLog(@"%@ %@", ok ? @"Wrote" : @"Failed to write", self.outputPath);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *outputPath = argc > 1
            ? [NSString stringWithUTF8String:argv[1]]
            : [[[NSFileManager defaultManager] currentDirectoryPath]
                stringByAppendingPathComponent:@"dist/xscreensaver-glmatrix-preview.png"];
        NSTimeInterval delay = argc > 2 ? atof(argv[2]) : 45.0;
        if (argc > 3) density = atof(argv[3]);
        if (argc > 4) speed = atof(argv[4]);

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        XScreenSaverPreviewController *controller = [[XScreenSaverPreviewController alloc]
            initWithOutputPath:outputPath
                  captureDelay:delay];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
