#ifndef ASTROCAT_H
#define ASTROCAT_H

#include <stddef.h>
#include <stdint.h>

typedef struct AcBuf AcBuf;
typedef struct AcThumb AcThumb;

typedef struct {
  uint32_t width;
  uint32_t height;
  uint32_t src_width;
  uint32_t src_height;
  uint32_t planes;
  float shadows_r;
  float shadows_g;
  float shadows_b;
  float midtone_r;
  float midtone_g;
  float midtone_b;
  float median;
  float mad;
  float pedestal;
  float exposure;
  float gain;
  float ccd_temp;
  float load_ms;
  float site_lat;
  float site_long;
  float full_scale;
  float focal_len;
  float pixel_size;
  float total_exp;
  uint32_t stack_count;
} AcInfo;

const char *ac_last_error(void);

AcBuf *ac_load_fits(const char *path, AcInfo *out);
/* scale > 0 forces the normalisation instead of this frame's own maximum. */
AcBuf *ac_load_fits_scaled(const char *path, float scale, AcInfo *out);
void ac_buf_free(AcBuf *buf);

const uint16_t *ac_buf_pixels(const AcBuf *buf);
size_t ac_buf_len(const AcBuf *buf);

const char *ac_buf_object(const AcBuf *buf);
const char *ac_buf_date_obs(const AcBuf *buf);
const char *ac_buf_bayer(const AcBuf *buf);
const char *ac_buf_telescope(const AcBuf *buf);
const char *ac_buf_filter(const AcBuf *buf);

typedef struct {
  uint32_t id;
  uint32_t session;
  uint32_t stars;
  uint32_t width;
  uint32_t height;
  int64_t second;
  float hfr;
  float ecc;
  float background;
  float noise;
  float quality;
  float exptime;
  float gain;
  float ccd_temp;
  int32_t rejected;
  float ra;
  float dec;
  float focal_len;
  float pixel_size;
  float scale;
  int32_t has_wcs;
  uint32_t trails;
} AcFrame;

typedef struct {
  uint32_t first;
  uint32_t count;
  uint32_t kept;
  float exptime;
  int64_t start;
  int64_t end;
} AcSession;

int32_t ac_catalog_open(const char *dir);
int32_t ac_catalog_build(const char *dir);
int32_t ac_catalog_save(void);

uint32_t ac_frame_count(void);
uint32_t ac_session_count(void);
int32_t ac_frame(uint32_t index, AcFrame *out);
int32_t ac_session(uint32_t index, AcSession *out);

const char *ac_frame_path(uint32_t index);
const char *ac_frame_date(uint32_t index);
const char *ac_frame_object(uint32_t index);
const char *ac_frame_telescope(uint32_t index);
const char *ac_frame_filter(uint32_t index);
const char *ac_session_night(uint32_t index);

void ac_set_rejected(uint32_t index, int32_t rejected);
uint32_t ac_cull_below(float threshold);

typedef struct {
  uint32_t files;
  uint32_t lights;
  uint32_t masters;
  uint32_t sessions;
  uint32_t groups;
  uint32_t unreadable;
  int64_t bytes;
} AcScanStats;

typedef struct {
  int32_t kind;
  uint32_t frames;
  uint32_t fresh;
  uint32_t present;
  float exptime;
  int64_t bytes;
  int64_t span;
  uint32_t gaps;
} AcGroup;

typedef struct {
  int32_t exists;
  uint32_t sessions;
  uint32_t frames;
  uint32_t kept;
  int64_t bytes;
  int64_t last_night;
} AcProject;

int32_t ac_scan(const char *dir, const char *project);
int32_t ac_scan_stats(AcScanStats *out);
int32_t ac_scan_group(uint32_t index, AcGroup *out);
const char *ac_group_name(uint32_t index);
const char *ac_group_spec(uint32_t index);
const char *ac_group_reason(uint32_t index);
const char *ac_group_file(uint32_t group, uint32_t frame);
const char *ac_header_text(const char *path);
int32_t ac_project_summary(const char *dir, AcProject *out);

typedef struct {
  int32_t state;
  int32_t stage;
  uint32_t done;
  uint32_t total;
  float elapsed;
  float eta;
  uint32_t frames_used;
  uint32_t frames_failed;
  float noise;
  float gradient;
  float clipped_pct;
  float rotation_min;
  float rotation_max;
  float drift_px;
  uint32_t stars;
  float analyse_s;
  float register_s;
  float combine_s;
} AcJob;

int32_t ac_stack_start(const char *paths, const char *out, float sigma_low,
                       float sigma_high, int32_t remove_gradient,
                       int32_t full_resolution, uint32_t drizzle);
void ac_job_cancel(void);
int32_t ac_job(AcJob *out);
const char *ac_job_message(void);
float ac_measure_noise(const char *path);
uint32_t ac_measure_stars(const char *path);
AcThumb *ac_thumbnail(const char *path, uint32_t max_dim);
AcThumb *ac_thumbnail_cached(const char *project, const char *path,
                             uint32_t max_dim);
const uint8_t *ac_thumb_pixels(const AcThumb *t);
uint32_t ac_thumb_width(const AcThumb *t);
uint32_t ac_thumb_height(const AcThumb *t);
void ac_thumb_free(AcThumb *t);

typedef struct {
  int32_t ok;
  uint32_t stars_found;
  uint32_t stars_used;
  float offset_r;
  float offset_g;
  float offset_b;
  float gain_r;
  float gain_g;
  float gain_b;
  float sky_r;
  float sky_g;
  float sky_b;
  float sky_after;
  float ratio_r;
  float ratio_b;
  float scatter_r;
  float scatter_b;
  float shadows_r;
  float shadows_g;
  float shadows_b;
  float midtone_r;
  float midtone_g;
  float midtone_b;
  float linked_shadows;
  float linked_midtone;
  uint32_t matched;
  float slope_r;
  float slope_b;
  float colour_span;
  float white;
  float median_colour;
  float ms;
} AcColorCal;

typedef struct {
  double ra;
  double dec;
  double radius_deg;
  double scale_arcsec;
  double rotation_deg;
  int32_t has_wcs;
  uint32_t width;
  uint32_t height;
  int32_t solved;
  uint32_t inliers;
  float rms_px;
} AcCone;

typedef struct {
  double ra0;
  double ra1;
  double dec0;
  double dec1;
  uint32_t index;
  int32_t done;
} AcTile;

typedef struct {
  double min_dec;
  double sky_fraction;
  uint64_t stars;
  uint64_t bytes;
  uint32_t tiles_total;
  uint32_t tiles_done;
  float mag_limit;
  int32_t open;
} AcCatalogStats;

/* reference: 0 = sky background, 1 = average field star. */
int32_t ac_color_calibrate(const char *path, int32_t reference, float tolerance,
                           AcColorCal *out);
/* 1 = ok, -1 = no WCS on the frame, -2 = catalogue has too few stars here. */
int32_t ac_color_calibrate_catalog(const char *path, float white,
                                   float tolerance, AcColorCal *out);
int32_t ac_filter_is_narrowband(const char *filter);
int32_t ac_frame_cone(const char *path, AcCone *out);

int32_t ac_sky_open(const char *dir, double min_dec, float mag_limit);
int32_t ac_sky_stats(AcCatalogStats *out);
int32_t ac_sky_next_tile(uint32_t from, AcTile *out);
int32_t ac_sky_append(uint32_t index, const char *csv, float mag);
int32_t ac_sky_split(uint32_t index);
int32_t ac_sky_flush(void);
void ac_sky_close(void);
double ac_sky_visible_min_dec(double latitude, double min_altitude);
double ac_sky_fraction(double min_dec);

int32_t ac_fits_swap_rb(const char *path);

typedef struct {
  float midtone[3];
  float scale;
} AcMlPrep;

/* Star-removal models are trained on stretched images; handing one a linear
   frame costs ~100x more clipped pixels. Stretch, infer, then unstretch. */
int32_t ac_fits_prestretch(const char *src, const char *dst, AcMlPrep *out);
/* In place, and only after any channel reordering. */
int32_t ac_fits_unstretch(const char *path, const AcMlPrep *prep);

float ac_gradient_amplitude(const char *path, int32_t after, float tolerance);
int32_t ac_export_fits(const char *src, const char *dst, int32_t bottom_up,
                       int32_t keep_pedestal);

#endif
