// SID Jukebox - macOS
// Commodore 64 SID music player using cSID emulator by Hermit
// Created by Serkan Tanriverdi - www.serkantanriverdi.com

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#include "sid_engine.h"

// ============================================================
#pragma mark - AppDelegate
// ============================================================

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSStatusItem *statusItem;
@end

// ============================================================
#pragma mark - SIDPlayerWindow
// ============================================================

@interface SIDPlayerWindow : NSObject <NSTableViewDelegate, NSTableViewDataSource>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSMutableArray *sidFiles;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, assign) AudioUnit audioUnit;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) int currentIndex;
// Player controls
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *authorLabel;
@property (nonatomic, strong) NSTextField *elapsedLabel;
@property (nonatomic, strong) NSTextField *remainingLabel;
@property (nonatomic, strong) NSSlider *progressSlider;
@property (nonatomic, strong) NSButton *playPauseBtn;
@property (nonatomic, strong) NSButton *prevBtn;
@property (nonatomic, strong) NSButton *nextBtn;
@property (nonatomic, strong) NSButton *stopBtn;
@property (nonatomic, strong) NSButton *modeBtn;
@property (nonatomic, strong) NSView *playerBar;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, assign) NSTimeInterval playbackTime;
@property (nonatomic, assign) NSTimeInterval trackDuration;
@property (nonatomic, assign) BOOL sliderDragging;
@property (nonatomic, assign) BOOL isSeeking;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, assign) int sortMode; // 0=Top, 1=A-Z
// Playback mode: 0=Sequential, 1=Shuffle, 2=Repeat One
@property (nonatomic, assign) int playbackMode;
// Playlists
@property (nonatomic, strong) NSMutableArray *playlists; // array of NSDictionary {name, paths}
@property (nonatomic, strong) NSDictionary *currentPlaylist; // nil = all tracks
@property (nonatomic, strong) NSMutableArray *displayFiles; // filtered list for current view
- (void)setup;
@end

static float gVolume = 0.8f;

// Audio render callback
static OSStatus renderCallback(void *inRefCon,
                                AudioUnitRenderActionFlags *ioActionFlags,
                                const AudioTimeStamp *inTimeStamp,
                                UInt32 inBusNumber,
                                UInt32 inNumberFrames,
                                AudioBufferList *ioData) {
    short *buffer = (short *)ioData->mBuffers[0].mData;
    sid_generate(buffer, inNumberFrames);
    float vol = gVolume;
    for (UInt32 i = 0; i < inNumberFrames; i++) {
        buffer[i] = (short)(buffer[i] * vol);
    }
    return noErr;
}

@implementation SIDPlayerWindow

- (void)setup {
    self.currentIndex = -1;
    self.trackDuration = 180.0;
    self.playbackMode = 0;
    cSID_init(44100);

    // Load playlists from UserDefaults
    NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"SIDJukeboxPlaylists"];
    if (saved) {
        self.playlists = [NSMutableArray array];
        for (NSDictionary *d in saved) {
            NSMutableDictionary *md = [NSMutableDictionary dictionary];
            md[@"name"] = d[@"name"];
            md[@"paths"] = [d[@"paths"] mutableCopy];
            [self.playlists addObject:md];
        }
    } else {
        self.playlists = [NSMutableArray array];
    }
    self.currentPlaylist = nil;

    // Window
    NSRect frame = NSMakeRect(200, 200, 500, 680);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"SID Jukebox";
    self.window.minSize = NSMakeSize(400, 450);
    self.window.backgroundColor = [NSColor colorWithRed:0.05 green:0.05 blue:0.1 alpha:1.0];

    NSView *content = self.window.contentView;

    // --- Toolbar area: Open button ---
    NSButton *openBtn = [NSButton buttonWithTitle:@"+ Add New" target:self action:@selector(openFile)];
    openBtn.frame = NSMakeRect(10, frame.size.height - 42, 70, 30);
    openBtn.autoresizingMask = NSViewMinYMargin;
    openBtn.bezelStyle = NSBezelStyleRounded;
    [content addSubview:openBtn];

    // Playlist button
    NSButton *playlistBtn = [NSButton buttonWithTitle:@"Playlist" target:self action:@selector(showPlaylistMenu:)];
    playlistBtn.frame = NSMakeRect(85, frame.size.height - 42, 80, 30);
    playlistBtn.autoresizingMask = NSViewMinYMargin;
    playlistBtn.bezelStyle = NSBezelStyleRounded;
    [content addSubview:playlistBtn];

    // Sort toggle
    NSSegmentedControl *sortCtrl = [NSSegmentedControl segmentedControlWithLabels:@[@"Top 100", @"A-Z"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(sortChanged:)];
    sortCtrl.frame = NSMakeRect(175, frame.size.height - 40, 140, 26);
    sortCtrl.selectedSegment = 0;
    sortCtrl.autoresizingMask = NSViewMinYMargin;
    [content addSubview:sortCtrl];

    // About button top-right
    NSButton *infoBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(showInfo)];
    infoBtn.frame = NSMakeRect(frame.size.width - 70, frame.size.height - 40, 60, 26);
    infoBtn.bezelStyle = NSBezelStyleInline;
    infoBtn.bordered = NO;
    infoBtn.font = [NSFont systemFontOfSize:12];
    infoBtn.attributedTitle = [[NSAttributedString alloc] initWithString:@"About"
        attributes:@{NSForegroundColorAttributeName: [NSColor colorWithRed:0.5 green:0.5 blue:0.7 alpha:1.0],
                      NSFontAttributeName: [NSFont systemFontOfSize:12]}];
    infoBtn.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [content addSubview:infoBtn];

    // --- Table (scroll view) ---
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height - 50)];
    NSScrollView *scrollView = self.scrollView;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSNoBorder;

    self.tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [NSColor colorWithRed:0.05 green:0.05 blue:0.1 alpha:1.0];
    self.tableView.rowHeight = 48;
    self.tableView.headerView = nil;
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.tableView.doubleAction = @selector(tableDoubleClick);
    self.tableView.target = self;

    // Context menu for right-click
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Context"];
    [contextMenu addItemWithTitle:@"Add to Playlist..." action:@selector(addToPlaylistContext:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Remove from Playlist" action:@selector(removeFromPlaylistContext:) keyEquivalent:@""];
    self.tableView.menu = contextMenu;
    for (NSMenuItem *item in contextMenu.itemArray) {
        item.target = self;
    }

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.width = frame.size.width - 20;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:col];

    scrollView.documentView = self.tableView;
    [content addSubview:scrollView];

    // --- Player bar (bottom) ---
    self.playerBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 215)];
    self.playerBar.autoresizingMask = NSViewWidthSizable;
    self.playerBar.wantsLayer = YES;
    self.playerBar.layer.backgroundColor = [NSColor colorWithRed:0.08 green:0.06 blue:0.14 alpha:0.98].CGColor;
    self.playerBar.hidden = YES;

    // Separator line
    NSView *sep = [[NSView alloc] initWithFrame:NSMakeRect(0, 174, frame.size.width, 1)];
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = [NSColor colorWithRed:1.0 green:0.67 blue:0.0 alpha:0.3].CGColor;
    sep.autoresizingMask = NSViewWidthSizable;
    [self.playerBar addSubview:sep];

    // Title (no C64 badge, starts at x=15)
    self.titleLabel = [NSTextField labelWithString:@""];
    self.titleLabel.frame = NSMakeRect(15, 142, 400, 22);
    self.titleLabel.font = [NSFont boldSystemFontOfSize:15];
    self.titleLabel.textColor = [NSColor colorWithRed:1.0 green:0.67 blue:0.0 alpha:1.0];
    self.titleLabel.autoresizingMask = NSViewWidthSizable;
    [self.playerBar addSubview:self.titleLabel];

    // Author
    self.authorLabel = [NSTextField labelWithString:@""];
    self.authorLabel.frame = NSMakeRect(15, 123, 400, 18);
    self.authorLabel.font = [NSFont systemFontOfSize:12];
    self.authorLabel.textColor = [NSColor lightGrayColor];
    self.authorLabel.autoresizingMask = NSViewWidthSizable;
    [self.playerBar addSubview:self.authorLabel];

    // --- Transport controls ---
    CGFloat midX = frame.size.width / 2;

    self.prevBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(prevTrack)];
    self.prevBtn.frame = NSMakeRect(midX - 85, 82, 40, 36);
    self.prevBtn.bezelStyle = NSBezelStyleInline;
    self.prevBtn.bordered = NO;
    {
        NSImage *prevImg = [NSImage imageWithSystemSymbolName:@"backward.end.fill" accessibilityDescription:@"Previous"];
        if (prevImg) {
            NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium];
            self.prevBtn.image = [prevImg imageWithSymbolConfiguration:cfg];
            self.prevBtn.imagePosition = NSImageOnly;
            self.prevBtn.contentTintColor = [NSColor whiteColor];
        } else {
            self.prevBtn.attributedTitle = [[NSAttributedString alloc] initWithString:@"\u23EE"
                attributes:@{NSForegroundColorAttributeName: [NSColor whiteColor], NSFontAttributeName: [NSFont systemFontOfSize:20]}];
        }
    }
    self.prevBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [self.playerBar addSubview:self.prevBtn];

    self.playPauseBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(togglePlayPause)];
    self.playPauseBtn.frame = NSMakeRect(midX - 22, 78, 44, 44);
    self.playPauseBtn.bezelStyle = NSBezelStyleInline;
    self.playPauseBtn.bordered = NO;
    self.playPauseBtn.font = [NSFont systemFontOfSize:26];
    [self updatePlayPauseButton];
    self.playPauseBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [self.playerBar addSubview:self.playPauseBtn];

    self.nextBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(nextTrack)];
    self.nextBtn.frame = NSMakeRect(midX + 45, 82, 40, 36);
    self.nextBtn.bezelStyle = NSBezelStyleInline;
    self.nextBtn.bordered = NO;
    {
        NSImage *nextImg = [NSImage imageWithSystemSymbolName:@"forward.end.fill" accessibilityDescription:@"Next"];
        if (nextImg) {
            NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium];
            self.nextBtn.image = [nextImg imageWithSymbolConfiguration:cfg];
            self.nextBtn.imagePosition = NSImageOnly;
            self.nextBtn.contentTintColor = [NSColor whiteColor];
        } else {
            self.nextBtn.attributedTitle = [[NSAttributedString alloc] initWithString:@"\u23ED"
                attributes:@{NSForegroundColorAttributeName: [NSColor whiteColor], NSFontAttributeName: [NSFont systemFontOfSize:20]}];
        }
    }
    self.nextBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [self.playerBar addSubview:self.nextBtn];

    // Playback mode button (next to transport controls)
    self.modeBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(cyclePlaybackMode)];
    self.modeBtn.frame = NSMakeRect(midX + 90, 86, 36, 28);
    self.modeBtn.bezelStyle = NSBezelStyleInline;
    self.modeBtn.bordered = NO;
    self.modeBtn.font = [NSFont systemFontOfSize:16];
    self.modeBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [self updateModeButton];
    [self.playerBar addSubview:self.modeBtn];

    // Stop button (right side)
    self.stopBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(stopPlayback)];
    self.stopBtn.frame = NSMakeRect(frame.size.width - 55, 86, 36, 32);
    self.stopBtn.bezelStyle = NSBezelStyleInline;
    self.stopBtn.bordered = NO;
    {
        NSImage *stopImg = [NSImage imageWithSystemSymbolName:@"stop.fill" accessibilityDescription:@"Stop"];
        if (stopImg) {
            NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
            self.stopBtn.image = [stopImg imageWithSymbolConfiguration:cfg];
            self.stopBtn.imagePosition = NSImageOnly;
            self.stopBtn.contentTintColor = [NSColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:1.0];
        } else {
            self.stopBtn.attributedTitle = [[NSAttributedString alloc] initWithString:@"Stop"
                attributes:@{NSForegroundColorAttributeName: [NSColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:1.0],
                              NSFontAttributeName: [NSFont boldSystemFontOfSize:13]}];
        }
    }
    self.stopBtn.autoresizingMask = NSViewMinXMargin;
    [self.playerBar addSubview:self.stopBtn];

    // --- Timeline ---
    self.elapsedLabel = [NSTextField labelWithString:@"0:00"];
    self.elapsedLabel.frame = NSMakeRect(10, 66, 45, 18);
    self.elapsedLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.elapsedLabel.textColor = [NSColor lightGrayColor];
    self.elapsedLabel.alignment = NSTextAlignmentRight;
    [self.playerBar addSubview:self.elapsedLabel];

    self.progressSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(60, 66, frame.size.width - 120, 20)];
    self.progressSlider.minValue = 0;
    self.progressSlider.maxValue = 180.0;
    self.progressSlider.doubleValue = 0;
    self.progressSlider.target = self;
    self.progressSlider.action = @selector(sliderChanged:);
    self.progressSlider.continuous = YES;
    self.progressSlider.autoresizingMask = NSViewWidthSizable;
    [self.playerBar addSubview:self.progressSlider];

    self.remainingLabel = [NSTextField labelWithString:@"-3:00"];
    self.remainingLabel.frame = NSMakeRect(frame.size.width - 55, 66, 45, 18);
    self.remainingLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.remainingLabel.textColor = [NSColor lightGrayColor];
    self.remainingLabel.alignment = NSTextAlignmentLeft;
    self.remainingLabel.autoresizingMask = NSViewMinXMargin;
    [self.playerBar addSubview:self.remainingLabel];

    // Volume - centered under timeline
    CGFloat volWidth = 160;
    CGFloat volX = (frame.size.width - volWidth) / 2;
    NSImage *volLo = [NSImage imageWithSystemSymbolName:@"speaker.fill" accessibilityDescription:nil];
    NSImage *volHi = [NSImage imageWithSystemSymbolName:@"speaker.wave.3.fill" accessibilityDescription:nil];
    if (volLo) {
        NSImageView *volLoIcon = [NSImageView imageViewWithImage:[volLo imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]]];
        volLoIcon.frame = NSMakeRect(volX, 34, 18, 18);
        volLoIcon.contentTintColor = [NSColor secondaryLabelColor];
        [self.playerBar addSubview:volLoIcon];
    }
    NSSlider *volSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(volX + 22, 34, volWidth - 44, 20)];
    volSlider.minValue = 0.0;
    volSlider.maxValue = 1.0;
    volSlider.doubleValue = 0.8;
    volSlider.target = self;
    volSlider.action = @selector(volumeChanged:);
    volSlider.continuous = YES;
    ((NSSliderCell *)volSlider.cell).sliderType = NSSliderTypeLinear;
    volSlider.trackFillColor = [NSColor systemBlueColor];
    [self.playerBar addSubview:volSlider];
    if (volHi) {
        NSImageView *volHiIcon = [NSImageView imageViewWithImage:[volHi imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]]];
        volHiIcon.frame = NSMakeRect(volX + volWidth - 20, 34, 20, 18);
        volHiIcon.contentTintColor = [NSColor secondaryLabelColor];
        [self.playerBar addSubview:volHiIcon];
    }

    // Copyright
    NSTextField *copyrightLabel = [NSTextField labelWithString:@"\u00A9 2026 Serkan Tanriverdi"];
    copyrightLabel.frame = NSMakeRect(0, 6, frame.size.width, 14);
    copyrightLabel.font = [NSFont systemFontOfSize:9];
    copyrightLabel.textColor = [NSColor tertiaryLabelColor];
    copyrightLabel.alignment = NSTextAlignmentCenter;
    copyrightLabel.autoresizingMask = NSViewWidthSizable;
    [self.playerBar addSubview:copyrightLabel];

    [content addSubview:self.playerBar];

    // Load bundled SIDs
    [self loadSIDFiles];

    [self.window makeKeyAndOrderFront:nil];
    [self.window center];
}

- (void)updatePlayPauseButton {
    NSColor *color = [NSColor colorWithRed:1.0 green:0.67 blue:0.0 alpha:1.0];
    NSString *symName = self.isPaused ? @"play.fill" : @"pause.fill";
    NSImage *img = [NSImage imageWithSystemSymbolName:symName accessibilityDescription:nil];
    if (img) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:22 weight:NSFontWeightMedium];
        self.playPauseBtn.image = [img imageWithSymbolConfiguration:cfg];
        self.playPauseBtn.imagePosition = NSImageOnly;
        self.playPauseBtn.contentTintColor = color;
        self.playPauseBtn.title = @"";
    } else {
        NSString *sym = self.isPaused ? @"\u25B6" : @"\u23F8";
        self.playPauseBtn.attributedTitle = [[NSAttributedString alloc] initWithString:sym
            attributes:@{NSForegroundColorAttributeName: color, NSFontAttributeName: [NSFont systemFontOfSize:26]}];
    }
}

- (void)updateModeButton {
    // Use NSImage SF Symbols if available (macOS 11+), fallback to text
    NSImage *img = nil;
    NSString *fallback;
    switch (self.playbackMode) {
        case 1:
            img = [NSImage imageWithSystemSymbolName:@"shuffle" accessibilityDescription:@"Shuffle"];
            fallback = @"Shfl";
            break;
        case 2:
            img = [NSImage imageWithSystemSymbolName:@"repeat.1" accessibilityDescription:@"Repeat One"];
            fallback = @"Rep1";
            break;
        default:
            img = [NSImage imageWithSystemSymbolName:@"arrow.forward" accessibilityDescription:@"Sequential"];
            fallback = @"Seq";
            break;
    }

    NSColor *color = (self.playbackMode == 0)
        ? [NSColor colorWithWhite:0.5 alpha:1.0]
        : [NSColor colorWithRed:1.0 green:0.67 blue:0.0 alpha:1.0];

    if (img) {
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
        img = [img imageWithSymbolConfiguration:config];
        self.modeBtn.image = img;
        self.modeBtn.imagePosition = NSImageOnly;
        self.modeBtn.contentTintColor = color;
        self.modeBtn.title = @"";
    } else {
        self.modeBtn.image = nil;
        self.modeBtn.imagePosition = NSNoImage;
        self.modeBtn.attributedTitle = [[NSAttributedString alloc] initWithString:fallback
            attributes:@{NSForegroundColorAttributeName: color, NSFontAttributeName: [NSFont boldSystemFontOfSize:10]}];
    }
}

- (void)cyclePlaybackMode {
    self.playbackMode = (self.playbackMode + 1) % 3;
    [self updateModeButton];
}

- (NSString *)formatTime:(NSTimeInterval)t {
    int mins = (int)t / 60;
    int secs = (int)t % 60;
    return [NSString stringWithFormat:@"%d:%02d", mins, secs];
}

#pragma mark - File Loading

- (void)loadSIDFiles {
    self.sidFiles = [NSMutableArray array];

    // Look for sids folder next to the binary
    NSString *appDir = [[NSBundle mainBundle] resourcePath];
    NSString *sidsDir = [appDir stringByAppendingPathComponent:@"sids"];

    // Also check parent directory (for development)
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir;
    if (![fm fileExistsAtPath:sidsDir isDirectory:&isDir] || !isDir) {
        // Try relative to executable
        NSString *execDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
        sidsDir = [execDir stringByAppendingPathComponent:@"sids"];
    }
    if (![fm fileExistsAtPath:sidsDir isDirectory:&isDir] || !isDir) {
        // Try CWD/sids
        sidsDir = [[fm currentDirectoryPath] stringByAppendingPathComponent:@"sids"];
    }

    if ([fm fileExistsAtPath:sidsDir isDirectory:&isDir] && isDir) {
        NSArray *files = [fm contentsOfDirectoryAtPath:sidsDir error:nil];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSString *f in files) {
            if ([f.pathExtension.lowercaseString isEqualToString:@"sid"]) {
                [paths addObject:[sidsDir stringByAppendingPathComponent:f]];
            }
        }
        [self.sidFiles addObjectsFromArray:paths];
    }

    [self sortFiles];
    [self refreshDisplayFiles];
    [self.tableView reloadData];
}

- (void)refreshDisplayFiles {
    if (self.currentPlaylist) {
        NSArray *paths = self.currentPlaylist[@"paths"];
        self.displayFiles = [NSMutableArray arrayWithArray:paths];
    } else {
        self.displayFiles = self.sidFiles;
    }
}

- (void)sortChanged:(NSSegmentedControl *)sender {
    int oldIndex = self.currentIndex;
    NSString *currentPath = nil;
    if (oldIndex >= 0 && oldIndex < (int)self.displayFiles.count) {
        currentPath = self.displayFiles[oldIndex];
    }

    self.sortMode = (int)sender.selectedSegment;
    [self sortFiles];
    [self refreshDisplayFiles];
    [self.tableView reloadData];

    // Preserve current playing track's index
    if (currentPath) {
        NSInteger newIdx = [self.displayFiles indexOfObject:currentPath];
        if (newIdx != NSNotFound) self.currentIndex = (int)newIdx;
    }
}

- (NSDictionary *)topRankings {
    // C64 SID all-time rankings based on community consensus (HVSC, Lemon64, CSDb polls)
    return @{
        // Tier 1 - Tartışmasız efsaneler
        @"Commando": @1, @"Monty_on_the_Run": @2, @"Last_Ninja_2": @3,
        @"International_Karate": @4, @"Wizball": @5, @"Great_Giana_Sisters": @6,
        @"Delta": @7, @"Turrican": @8, @"Sanxion": @9, @"Last_Ninja": @10,
        // Tier 2 - Kült klasikler
        @"Green_Beret": @11, @"Uridium": @12, @"Arkanoid": @13,
        @"Ghosts_n_Goblins": @14, @"R-Type": @15, @"Barbarian": @16,
        @"Crazy_Comets": @17, @"Ocean_Loader_2": @18, @"Turbo_Outrun": @19,
        @"IK_Plus": @20,
        // Tier 3 - Altin cag hitleri
        @"Robocop": @21, @"Lightforce": @22, @"Parallax": @23,
        @"Katakis": @24, @"Thing_on_a_Spring": @25, @"Cybernoid_II": @26,
        @"Cybernoid": @27, @"Creatures": @28, @"Lemmings": @29,
        @"Maniac_Mansion": @30,
        // Tier 4 - Hubbard & Galway saheserleri
        @"Knucklebusters": @31, @"Flash_Gordon": @32, @"Warhawk": @33,
        @"Ghouls_n_Ghosts": @34, @"Auf_Wiedersehen_Monty": @35,
        @"Nemesis_the_Warlock": @36, @"Cobra": @37, @"Platoon": @38,
        @"Game_Over": @39, @"Bionic_Commando": @40,
        // Tier 5 - Cok sevilen oyun muzikleri
        @"Lazy_Jones": @41, @"Paperboy": @42, @"Silkworm": @43,
        @"Comic_Bakery": @44, @"Flimbos_Quest": @45, @"Flimbos_Quest_Intro": @46,
        @"Jet_Set_Willy": @47, @"Forbidden_Forest": @48,
        @"Zak_McKracken": @49, @"Impossible_Mission_II": @50,
        // Tier 6 - Topluluk favorileri
        @"Spellbound": @51, @"Master_of_Magic": @52, @"Zoids": @53,
        @"Myth": @54, @"Hawkeye": @55, @"Trap": @56,
        @"Mega_Apocalypse": @57, @"Dominator": @58, @"Supremacy": @59,
        @"Terra_Cresta": @60,
        // Tier 7 - Gizli hazineler
        @"Firelord": @61, @"Driller": @62, @"Thrust": @63,
        @"Hades_Nebula": @64, @"Saboteur_II": @65, @"Vendetta": @66,
        @"Mikie": @67, @"Ping_Pong": @68, @"Krakout": @69,
        @"Robocop_3": @70,
        // Tier 8 - Nadir guzellikler
        @"Rasputin": @71, @"ACE_II": @72, @"Chimera": @73,
        @"Scumball": @74, @"Deflektor": @75, @"Ocean_Loader_4": @76,
        @"Short_Circuit": @77, @"Rambo_First_Blood_Part_II": @78,
        @"Battle_of_Britain": @79, @"Athena": @80,
        // Tier 9 - Koleksiyon parcalari
        @"Kentilla": @81, @"Human_Race": @82, @"Phantoms_of_the_Asteroid": @83,
        @"Raw_Recruit": @84, @"Gauntlet_III": @85, @"Acid": @86,
        @"Rubicon": @87, @"Glider_Rider": @88, @"Quedex": @89,
        @"Thanatos": @90,
        // Tier 10 - Tamamlayicilar
        @"Mutants": @91, @"Gem_X": @92, @"Grand_Monster_Slam": @93,
        @"Agent_X_II": @94, @"Bangkok_Knights": @95,
        @"Soldier_of_Fortune": @96, @"Zoolook": @97, @"Tusker": @98,
        @"One_Man_and_his_Droid": @99, @"Treasure_Island_Dizzy": @100,
        @"Dragons_Lair_Part_II": @101
    };
}

- (NSDictionary *)trackLengths {
    return @{
        @"ACE_II": @312, @"Acid": @76, @"Agent_X_II": @154,
        @"Arkanoid": @142, @"Athena": @120, @"Auf_Wiedersehen_Monty": @368,
        @"Bangkok_Knights": @383, @"Barbarian": @377, @"Battle_of_Britain": @231,
        @"Bionic_Commando": @60, @"Chimera": @219, @"Cobra": @186,
        @"Comic_Bakery": @189, @"Commando": @235, @"Crazy_Comets": @276,
        @"Creatures": @75, @"Cybernoid": @400, @"Cybernoid_II": @346,
        @"Deflektor": @171, @"Delta": @682, @"Dominator": @217,
        @"Dragons_Lair_Part_II": @62, @"Driller": @521, @"Firelord": @170,
        @"Flash_Gordon": @388, @"Flimbos_Quest": @115, @"Flimbos_Quest_Intro": @137,
        @"Forbidden_Forest": @91, @"Game_Over": @310, @"Gauntlet_III": @135,
        @"Gem_X": @244, @"Ghosts_n_Goblins": @147, @"Ghouls_n_Ghosts": @259,
        @"Glider_Rider": @100, @"Grand_Monster_Slam": @218, @"Great_Giana_Sisters": @221,
        @"Green_Beret": @213, @"Hades_Nebula": @99, @"Hawkeye": @385,
        @"Human_Race": @164, @"Impossible_Mission_II": @60, @"International_Karate": @645,
        @"Jet_Set_Willy": @177, @"Katakis": @333, @"Kentilla": @779,
        @"Knucklebusters": @1002, @"Krakout": @170, @"Last_Ninja": @292,
        @"Last_Ninja_2": @267, @"Lazy_Jones": @60, @"Lemmings": @60,
        @"Lightforce": @433, @"Maniac_Mansion": @88, @"Master_of_Magic": @321,
        @"Mega_Apocalypse": @441, @"Mikie": @289, @"Monty_on_the_Run": @350,
        @"Mutants": @250, @"Myth": @266, @"Nemesis_the_Warlock": @412,
        @"Ocean_Loader_2": @253, @"Ocean_Loader_4": @192, @"One_Man_and_his_Droid": @347,
        @"Paperboy": @76, @"Parallax": @683, @"Phantoms_of_the_Asteroid": @255,
        @"Ping_Pong": @60, @"Platoon": @123, @"Quedex": @241,
        @"R-Type": @131, @"Rambo_First_Blood_Part_II": @216, @"Rasputin": @307,
        @"Raw_Recruit": @110, @"Robocop": @193, @"Robocop_3": @235,
        @"Rubicon": @245, @"Saboteur_II": @258, @"Sanxion": @334,
        @"Scumball": @75, @"Short_Circuit": @241, @"Silkworm": @142,
        @"Soldier_of_Fortune": @91, @"Spellbound": @341, @"Supremacy": @231,
        @"Terra_Cresta": @221, @"Thanatos": @60, @"Thing_on_a_Spring": @218,
        @"Thrust": @402, @"Trap": @586, @"Treasure_Island_Dizzy": @60,
        @"Turbo_Outrun": @475, @"Turrican": @99, @"Tusker": @340,
        @"Uridium": @60, @"Vendetta": @354, @"Warhawk": @264,
        @"Wizball": @60, @"Zak_McKracken": @86, @"Zoids": @304,
        @"Zoolook": @259
    };
}

- (NSTimeInterval)durationForFile:(NSString *)path {
    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    NSNumber *len = [self trackLengths][name];
    return len ? len.doubleValue : 180.0;
}

- (void)sortFiles {
    if (self.sortMode == 0) {
        // Top ranking
        NSDictionary *ranks = [self topRankings];
        [self.sidFiles sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSString *nameA = [[a lastPathComponent] stringByDeletingPathExtension];
            NSString *nameB = [[b lastPathComponent] stringByDeletingPathExtension];
            NSNumber *rA = ranks[nameA] ?: @999;
            NSNumber *rB = ranks[nameB] ?: @999;
            return [rA compare:rB];
        }];
    } else {
        // Alphabetical by display name
        [self.sidFiles sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSString *nameA = [[[a lastPathComponent] stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
            NSString *nameB = [[[b lastPathComponent] stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
            return [nameA localizedCaseInsensitiveCompare:nameB];
        }];
    }
}

- (NSString *)authorFromFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length >= 0x56) {
        NSString *author = [[NSString alloc] initWithBytes:(const char *)[data bytes]+0x36 length:32 encoding:NSASCIIStringEncoding];
        return [author stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]] ?: @"";
    }
    return @"";
}

#pragma mark - Info Panel (Retro)

- (void)showInfo {
    // Reuse existing window if it exists
    static NSWindow *infoWin = nil;
    if (infoWin) {
        [infoWin makeKeyAndOrderFront:nil];
        return;
    }

    NSRect winFrame = NSMakeRect(0, 0, 460, 480);
    infoWin = [[NSWindow alloc] initWithContentRect:winFrame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    infoWin.title = @"About SID Jukebox";
    infoWin.releasedWhenClosed = NO;
    infoWin.backgroundColor = [NSColor colorWithRed:0.06 green:0.04 blue:0.12 alpha:1.0];

    NSView *cv = infoWin.contentView;

    // ScrollView wrapping the text
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:cv.bounds];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller = YES;
    sv.borderType = NSNoBorder;
    sv.drawsBackground = NO;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, winFrame.size.width, 0)];
    tv.editable = NO;
    tv.selectable = YES;
    tv.drawsBackground = NO;
    tv.textContainerInset = NSMakeSize(25, 25);
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;

    NSColor *amber = [NSColor colorWithRed:1.0 green:0.67 blue:0.0 alpha:1.0];
    NSColor *dimAmber = [NSColor colorWithRed:0.7 green:0.45 blue:0.0 alpha:0.5];
    NSColor *brightAmber = [NSColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0];
    NSColor *dimText = [NSColor colorWithRed:0.7 green:0.55 blue:0.2 alpha:0.7];
    NSFont *monoFont = [NSFont fontWithName:@"Menlo" size:12] ?: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont fontWithName:@"Menlo-Bold" size:15] ?: [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightBold];
    NSFont *monoSmall = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineSpacing = 5.0;
    ps.paragraphSpacing = 6.0;

    NSMutableParagraphStyle *titlePs = [[NSMutableParagraphStyle alloc] init];
    titlePs.lineSpacing = 8.0;
    titlePs.paragraphSpacing = 2.0;

    NSMutableParagraphStyle *borderPs = [[NSMutableParagraphStyle alloc] init];
    borderPs.lineSpacing = 0;
    borderPs.paragraphSpacingBefore = 10.0;
    borderPs.paragraphSpacing = 10.0;

    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];

    void (^add)(NSString *, NSFont *, NSColor *, NSParagraphStyle *) = ^(NSString *str, NSFont *font, NSColor *color, NSParagraphStyle *style) {
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:str
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: style}]];
    };

    NSString *line = @"\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500";

    add(@"SID JUKEBOX\n", monoBold, brightAmber, titlePs);
    add(@"Commodore 64 SID Music Player\n", monoFont, amber, ps);
    add([NSString stringWithFormat:@"%@\n", line], monoSmall, dimAmber, borderPs);

    add(@"100 legendary chiptunes from the\ngolden era of the Commodore 64.\n", monoFont, amber, ps);

    add(@"Powered by cSID emulator by Hermit,\nemulating the MOS 6581/8580 SID chip\nthat defined a generation of game music.\n", monoFont, dimText, ps);
    add([NSString stringWithFormat:@"%@\n", line], monoSmall, dimAmber, borderPs);

    add(@"Composers\n", monoFont, amber, ps);
    add(@"Rob Hubbard \u2022 Martin Galway\nBen Daglish \u2022 Jeroen Tel\nTim Follin \u2022 Matt Gray\nChris Huelsbeck \u2022 David Whittaker\nand many more legends...\n", monoSmall, dimText, ps);
    add([NSString stringWithFormat:@"%@\n", line], monoSmall, dimAmber, borderPs);

    add(@"Created by\n", monoSmall, dimAmber, ps);
    add(@"Serkan Tanriverdi\n", monoBold, brightAmber, titlePs);
    add(@"www.serkantanriverdi.com\n", monoFont, amber, ps);
    add([NSString stringWithFormat:@"%@\n", line], monoSmall, dimAmber, borderPs);

    add(@"LOAD \"*\",8,1\nREADY. \u2588\n", monoFont, dimText, ps);

    [tv.textStorage setAttributedString:as];

    sv.documentView = tv;
    [cv addSubview:sv];

    [infoWin center];
    [infoWin makeKeyAndOrderFront:nil];
}

#pragma mark - Playlists

- (void)savePlaylists {
    [[NSUserDefaults standardUserDefaults] setObject:self.playlists forKey:@"SIDJukeboxPlaylists"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)showPlaylistMenu:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Playlists"];

    // All Tracks
    NSMenuItem *allItem = [[NSMenuItem alloc] initWithTitle:@"All Tracks" action:@selector(selectAllTracks) keyEquivalent:@""];
    allItem.target = self;
    if (!self.currentPlaylist) allItem.state = NSControlStateValueOn;
    [menu addItem:allItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // New Playlist
    NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:@"New Playlist..." action:@selector(createNewPlaylist) keyEquivalent:@""];
    newItem.target = self;
    [menu addItem:newItem];

    if (self.playlists.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];

        // Existing playlists
        for (NSUInteger i = 0; i < self.playlists.count; i++) {
            NSDictionary *pl = self.playlists[i];
            NSString *title = [NSString stringWithFormat:@"%@ (%lu)", pl[@"name"], (unsigned long)[pl[@"paths"] count]];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectPlaylist:) keyEquivalent:@""];
            item.target = self;
            item.tag = (NSInteger)i;
            if (self.currentPlaylist == pl) item.state = NSControlStateValueOn;
            [menu addItem:item];
        }

        [menu addItem:[NSMenuItem separatorItem]];

        // Delete playlist submenu
        NSMenuItem *deleteItem = [[NSMenuItem alloc] initWithTitle:@"Delete Playlist..." action:nil keyEquivalent:@""];
        NSMenu *delSub = [[NSMenu alloc] initWithTitle:@"Delete"];
        for (NSUInteger i = 0; i < self.playlists.count; i++) {
            NSDictionary *pl = self.playlists[i];
            NSMenuItem *di = [[NSMenuItem alloc] initWithTitle:pl[@"name"] action:@selector(deletePlaylist:) keyEquivalent:@""];
            di.target = self;
            di.tag = (NSInteger)i;
            [delSub addItem:di];
        }
        deleteItem.submenu = delSub;
        [menu addItem:deleteItem];
    }

    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.frame.size.height) inView:sender];
}

- (void)selectAllTracks {
    self.currentPlaylist = nil;
    [self refreshDisplayFiles];
    [self.tableView reloadData];
    self.window.title = @"SID Jukebox";
}

- (void)selectPlaylist:(NSMenuItem *)item {
    NSUInteger idx = (NSUInteger)item.tag;
    if (idx < self.playlists.count) {
        self.currentPlaylist = self.playlists[idx];
        [self refreshDisplayFiles];
        self.currentIndex = -1;
        [self.tableView reloadData];
        self.window.title = [NSString stringWithFormat:@"SID Jukebox - %@", self.currentPlaylist[@"name"]];
    }
}

- (void)deletePlaylist:(NSMenuItem *)item {
    NSUInteger idx = (NSUInteger)item.tag;
    if (idx < self.playlists.count) {
        if (self.currentPlaylist == self.playlists[idx]) {
            self.currentPlaylist = nil;
            [self refreshDisplayFiles];
        }
        [self.playlists removeObjectAtIndex:idx];
        [self savePlaylists];
        [self.tableView reloadData];
    }
}

- (void)createNewPlaylist {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"New Playlist";
    alert.informativeText = @"Enter a name for the playlist:";
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 250, 24)];
    input.placeholderString = @"My Playlist";
    alert.accessoryView = input;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            NSString *name = input.stringValue;
            if (name.length == 0) name = @"My Playlist";

            // Get selected rows
            NSIndexSet *sel = self.tableView.selectedRowIndexes;
            NSMutableArray *paths = [NSMutableArray array];
            [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
                if (idx < self.displayFiles.count) {
                    [paths addObject:self.displayFiles[idx]];
                }
            }];

            NSMutableDictionary *playlist = [NSMutableDictionary dictionary];
            playlist[@"name"] = name;
            playlist[@"paths"] = paths;
            [self.playlists addObject:playlist];
            [self savePlaylists];
        }
    }];
}

- (void)addToPlaylistContext:(NSMenuItem *)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.displayFiles.count) return;
    NSString *path = self.displayFiles[row];

    if (self.playlists.count == 0) {
        // No playlists, prompt to create
        [self createNewPlaylist];
        return;
    }

    // Show submenu to pick playlist
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Add to"];
    for (NSUInteger i = 0; i < self.playlists.count; i++) {
        NSMutableDictionary *pl = self.playlists[i];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:pl[@"name"] action:@selector(addTrackToPlaylist:) keyEquivalent:@""];
        item.target = self;
        item.tag = (NSInteger)i;
        item.representedObject = path;
        [menu addItem:item];
    }
    [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}

- (void)addTrackToPlaylist:(NSMenuItem *)item {
    NSUInteger idx = (NSUInteger)item.tag;
    NSString *path = item.representedObject;
    if (idx < self.playlists.count && path) {
        NSMutableArray *paths = self.playlists[idx][@"paths"];
        if (![paths containsObject:path]) {
            [paths addObject:path];
            [self savePlaylists];
        }
    }
}

- (void)removeFromPlaylistContext:(NSMenuItem *)sender {
    if (!self.currentPlaylist) return;
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.displayFiles.count) return;

    NSString *path = self.displayFiles[row];
    NSMutableArray *paths = self.currentPlaylist[@"paths"];
    [paths removeObject:path];
    [self savePlaylists];
    [self refreshDisplayFiles];
    [self.tableView reloadData];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(removeFromPlaylistContext:)) {
        return self.currentPlaylist != nil;
    }
    return YES;
}

- (void)openFile {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"sid"];
    panel.allowsMultipleSelection = YES;
    panel.title = @"Open SID Files";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            int firstNew = (int)self.sidFiles.count;
            for (NSURL *url in panel.URLs) {
                NSString *path = url.path;
                if (![self.sidFiles containsObject:path]) {
                    [self.sidFiles addObject:path];
                }
            }
            [self refreshDisplayFiles];
            [self.tableView reloadData];
            // Auto-play first new file
            if (firstNew < (int)self.sidFiles.count) {
                NSString *newPath = self.sidFiles[firstNew];
                NSInteger dispIdx = [self.displayFiles indexOfObject:newPath];
                if (dispIdx != NSNotFound) {
                    self.currentIndex = (int)dispIdx;
                    [self playSIDFile:newPath];
                }
            }
        }
    }];
}

#pragma mark - Audio

- (void)setupAudioUnit {
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_DefaultOutput,  // macOS
        .componentManufacturer = kAudioUnitManufacturer_Apple
    };

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstanceNew(comp, &_audioUnit);

    AudioStreamBasicDescription fmt = {
        .mSampleRate = 44100,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 2,
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = 16
    };

    AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));

    AURenderCallbackStruct cb = { .inputProc = renderCallback, .inputProcRefCon = (__bridge void *)self };
    AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &cb, sizeof(cb));

    AudioUnitInitialize(_audioUnit);
}

- (void)playSIDFile:(NSString *)path {
    [self cleanupAudio];

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < 0x7C) return;

    cSID_init(44100);

    int result = sid_load((const byte *)[data bytes], (int)[data length], 0);
    if (result != 0) return;

    NSString *title = [NSString stringWithUTF8String:sid_title()];
    NSString *author = [NSString stringWithUTF8String:sid_author()];

    if (title.length == 0) {
        title = [[[path lastPathComponent] stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    }

    [self setupAudioUnit];
    AudioOutputUnitStart(_audioUnit);
    self.isPlaying = YES;
    self.isPaused = NO;

    self.titleLabel.stringValue = title;
    self.authorLabel.stringValue = author.length > 0 ? author : @"Unknown";
    [self updatePlayPauseButton];
    self.playerBar.hidden = NO;
    // Resize scroll view to make room for player bar
    NSRect sf = self.scrollView.frame;
    sf.origin.y = 215;
    sf.size.height = self.window.contentView.frame.size.height - 50 - 215;
    self.scrollView.frame = sf;

    self.playbackTime = 0;
    self.trackDuration = [self durationForFile:path];
    self.progressSlider.maxValue = self.trackDuration;
    self.progressSlider.doubleValue = 0;
    self.elapsedLabel.stringValue = @"0:00";
    int rm = (int)self.trackDuration / 60, rs = (int)self.trackDuration % 60;
    self.remainingLabel.stringValue = [NSString stringWithFormat:@"-%d:%02d", rm, rs];

    [self.progressTimer invalidate];
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateProgress) userInfo:nil repeats:YES];

    [self.tableView reloadData];
    self.window.title = [NSString stringWithFormat:@"SID Jukebox - %@", title];
}

// Cleanup audio only (used internally before playing new track)
- (void)cleanupAudio {
    self.isSeeking = NO;

    [self.progressTimer invalidate];
    self.progressTimer = nil;

    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }
    self.isPlaying = NO;
    self.isPaused = NO;
    self.playbackTime = 0;
}

// Full stop (user pressed Stop)
- (void)stopPlayback {
    [self cleanupAudio];
    self.playerBar.hidden = YES;
    self.currentIndex = -1;
    // Restore scroll view to full height
    NSRect sf = self.scrollView.frame;
    sf.origin.y = 0;
    sf.size.height = self.window.contentView.frame.size.height - 50;
    self.scrollView.frame = sf;
    [self.tableView reloadData];
    self.window.title = @"SID Jukebox";
}

#pragma mark - Transport

- (void)togglePlayPause {
    if (!self.isPlaying) return;

    if (self.isPaused) {
        AudioOutputUnitStart(_audioUnit);
        self.isPaused = NO;
    } else {
        AudioOutputUnitStop(_audioUnit);
        self.isPaused = YES;
    }
    [self updatePlayPauseButton];
}

- (void)prevTrack {
    if (self.displayFiles.count == 0) return;
    if (self.playbackTime > 3.0 && self.currentIndex >= 0) {
        [self playSIDFile:self.displayFiles[self.currentIndex]];
        return;
    }
    int idx = self.currentIndex - 1;
    if (idx < 0) idx = (int)self.displayFiles.count - 1;
    self.currentIndex = idx;
    [self playSIDFile:self.displayFiles[idx]];
}

- (void)nextTrack {
    if (self.displayFiles.count == 0) return;

    int idx;
    switch (self.playbackMode) {
        case 1: // Shuffle
            idx = arc4random_uniform((uint32_t)self.displayFiles.count);
            break;
        case 2: // Repeat One
            idx = self.currentIndex;
            if (idx < 0) idx = 0;
            break;
        default: // Sequential
            idx = self.currentIndex + 1;
            if (idx >= (int)self.displayFiles.count) idx = 0;
            break;
    }
    self.currentIndex = idx;
    [self playSIDFile:self.displayFiles[idx]];
}

#pragma mark - Progress

- (void)updateProgress {
    if (!self.isPlaying || self.isPaused) return;

    self.playbackTime += 0.5;

    // Auto-next when track reaches duration
    if (self.playbackTime >= self.trackDuration) {
        if (self.playbackMode == 0) {
            // Sequential: stop at end of list
            int nextIdx = self.currentIndex + 1;
            if (nextIdx >= (int)self.displayFiles.count) {
                [self stopPlayback];
                return;
            }
        }
        [self nextTrack];
        return;
    }

    self.progressSlider.doubleValue = self.playbackTime;
    self.elapsedLabel.stringValue = [self formatTime:self.playbackTime];
    NSTimeInterval rem = self.trackDuration - self.playbackTime;
    self.remainingLabel.stringValue = [NSString stringWithFormat:@"-%@", [self formatTime:rem]];
}

- (void)volumeChanged:(NSSlider *)sender {
    gVolume = (float)sender.doubleValue;
}

- (void)sliderChanged:(NSSlider *)sender {
    if (!self.isPlaying || self.currentIndex < 0) return;

    // Update time labels while dragging
    NSTimeInterval targetTime = sender.doubleValue;
    self.elapsedLabel.stringValue = [self formatTime:targetTime];
    NSTimeInterval rem = self.trackDuration - targetTime;
    self.remainingLabel.stringValue = [NSString stringWithFormat:@"-%@", [self formatTime:rem]];

    // Detect mouse-up: when event type is leftMouseUp, do actual seek
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeLeftMouseUp) {
        [self seekToTime:targetTime];
    }
}

- (void)seekToTime:(NSTimeInterval)targetTime {
    if (self.isSeeking) return;
    if (self.currentIndex < 0 || self.currentIndex >= (int)self.displayFiles.count) return;

    NSString *path = self.displayFiles[self.currentIndex];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < 0x7C) return;

    self.isSeeking = YES;

    // Stop current audio
    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }

    // Reinit engine and reload on main thread (frame skip is fast enough)
    cSID_init(44100);
    sid_load((const byte *)[data bytes], (int)[data length], 0);

    // Fast-forward by skipping frames (PAL = ~50 fps)
    int framesToSkip = (int)(targetTime * 50.0);
    sid_skip_frames(framesToSkip);

    // Restart audio
    [self setupAudioUnit];
    AudioOutputUnitStart(_audioUnit);

    self.playbackTime = targetTime;
    self.isPaused = NO;
    [self updatePlayPauseButton];
    self.elapsedLabel.stringValue = [self formatTime:self.playbackTime];
    NSTimeInterval r = self.trackDuration - self.playbackTime;
    self.remainingLabel.stringValue = [NSString stringWithFormat:@"-%@", [self formatTime:r]];

    self.isSeeking = NO;
}

#pragma mark - TableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.displayFiles.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *path = self.displayFiles[row];
    NSString *name = [[[path lastPathComponent] stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"_" withString:@" "];

    // Read author from SID header
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *author = @"";
    if (data.length >= 0x56) {
        const char *bytes = [data bytes];
        author = [[NSString alloc] initWithBytes:bytes+0x36 length:32 encoding:NSASCIIStringEncoding];
        author = [author stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]];
    }

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"cell" owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableView.frame.size.width, 48)];
        cell.identifier = @"cell";

        NSTextField *titleField = [NSTextField labelWithString:@""];
        titleField.frame = NSMakeRect(12, 24, tableView.frame.size.width - 50, 20);
        titleField.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        titleField.tag = 100;
        titleField.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:titleField];

        NSTextField *authorField = [NSTextField labelWithString:@""];
        authorField.frame = NSMakeRect(12, 6, tableView.frame.size.width - 50, 16);
        authorField.font = [NSFont systemFontOfSize:11];
        authorField.tag = 101;
        authorField.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:authorField];

        NSTextField *indicator = [NSTextField labelWithString:@""];
        indicator.frame = NSMakeRect(tableView.frame.size.width - 35, 14, 25, 22);
        indicator.font = [NSFont systemFontOfSize:18];
        indicator.alignment = NSTextAlignmentCenter;
        indicator.tag = 102;
        indicator.autoresizingMask = NSViewMinXMargin;
        [cell addSubview:indicator];
    }

    NSTextField *titleField = [cell viewWithTag:100];
    NSTextField *authorField = [cell viewWithTag:101];
    NSTextField *indicator = [cell viewWithTag:102];

    if (self.sortMode == 0 && !self.currentPlaylist) {
        titleField.stringValue = [NSString stringWithFormat:@"#%ld  %@", (long)row + 1, name];
    } else {
        titleField.stringValue = name;
    }
    authorField.stringValue = author;

    BOOL isCurrent = (row == self.currentIndex && self.isPlaying);
    NSColor *amber = [NSColor colorWithRed:1.0 green:0.67 blue:0.0 alpha:1.0];

    titleField.textColor = isCurrent ? amber : [NSColor whiteColor];
    authorField.textColor = isCurrent ? [NSColor colorWithRed:1.0 green:0.67 blue:0.0 alpha:0.7] : [NSColor grayColor];
    indicator.stringValue = isCurrent ? @"\u266A" : @"";
    indicator.textColor = amber;

    return cell;
}

- (void)tableDoubleClick {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.displayFiles.count) return;
    self.currentIndex = (int)row;
    [self playSIDFile:self.displayFiles[row]];
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return YES;
}

@end

// ============================================================
#pragma mark - AppDelegate Implementation
// ============================================================

static SIDPlayerWindow *playerWindow;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    playerWindow = [[SIDPlayerWindow alloc] init];
    [playerWindow setup];

    // Create menu bar
    NSMenu *menuBar = [[NSMenu alloc] init];

    // App menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"SID Jukebox"];
    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About SID Jukebox" action:@selector(showInfo) keyEquivalent:@""];
    aboutItem.target = playerWindow;
    [appMenu addItem:aboutItem];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide SID Jukebox" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@""];
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit SID Jukebox" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    // File menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open SID File..." action:@selector(openFile) keyEquivalent:@"o"];
    openItem.target = playerWindow;
    [fileMenu addItem:openItem];
    fileMenuItem.submenu = fileMenu;

    // Playback menu
    NSMenuItem *playMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:playMenuItem];
    NSMenu *playMenu = [[NSMenu alloc] initWithTitle:@"Playback"];

    NSMenuItem *ppItem = [[NSMenuItem alloc] initWithTitle:@"Play/Pause" action:@selector(togglePlayPause) keyEquivalent:@"p"];
    ppItem.target = playerWindow;
    [playMenu addItem:ppItem];

    NSMenuItem *nextItem = [[NSMenuItem alloc] initWithTitle:@"Next Track" action:@selector(nextTrack) keyEquivalent:@"n"];
    nextItem.target = playerWindow;
    [playMenu addItem:nextItem];

    NSMenuItem *prevItem = [[NSMenuItem alloc] initWithTitle:@"Previous Track" action:@selector(prevTrack) keyEquivalent:@"b"];
    prevItem.target = playerWindow;
    [playMenu addItem:prevItem];

    [playMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *stopItem = [[NSMenuItem alloc] initWithTitle:@"Stop" action:@selector(stopPlayback) keyEquivalent:@"s"];
    stopItem.target = playerWindow;
    stopItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [playMenu addItem:stopItem];

    playMenuItem.submenu = playMenu;

    // Window menu
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [NSApp setWindowsMenu:windowMenu];
    windowMenuItem.submenu = windowMenu;

    [NSApp setMainMenu:menuBar];

    // --- Status bar (tray) item ---
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *trayIcon = [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:@"SID Jukebox"];
    if (trayIcon) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
        trayIcon = [trayIcon imageWithSymbolConfiguration:cfg];
        [trayIcon setTemplate:YES];
        self.statusItem.button.image = trayIcon;
    } else {
        self.statusItem.button.title = @"\u266A";
    }

    NSMenu *trayMenu = [[NSMenu alloc] init];

    NSMenuItem *trayShow = [[NSMenuItem alloc] initWithTitle:@"Show SID Jukebox" action:@selector(showWindow) keyEquivalent:@""];
    trayShow.target = self;
    [trayMenu addItem:trayShow];

    [trayMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *trayPP = [[NSMenuItem alloc] initWithTitle:@"Play/Pause" action:@selector(togglePlayPause) keyEquivalent:@""];
    trayPP.target = playerWindow;
    [trayMenu addItem:trayPP];

    NSMenuItem *trayNext = [[NSMenuItem alloc] initWithTitle:@"Next Track" action:@selector(nextTrack) keyEquivalent:@""];
    trayNext.target = playerWindow;
    [trayMenu addItem:trayNext];

    NSMenuItem *trayPrev = [[NSMenuItem alloc] initWithTitle:@"Previous Track" action:@selector(prevTrack) keyEquivalent:@""];
    trayPrev.target = playerWindow;
    [trayMenu addItem:trayPrev];

    NSMenuItem *trayStop = [[NSMenuItem alloc] initWithTitle:@"Stop" action:@selector(stopPlayback) keyEquivalent:@""];
    trayStop.target = playerWindow;
    [trayMenu addItem:trayStop];

    [trayMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *trayQuit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""];
    [trayMenu addItem:trayQuit];

    self.statusItem.menu = trayMenu;

    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showWindow {
    [playerWindow.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO; // Keep running in tray when window closed
}

@end

// ============================================================
#pragma mark - Main
// ============================================================

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
