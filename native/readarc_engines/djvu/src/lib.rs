use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

use djvu_rs::Document;

#[repr(C)]
pub struct ReadArcDjvuPageInfo {
    pub width: u32,
    pub height: u32,
    pub dpi: u32,
}

pub struct ReadArcDjvuDocument {
    doc: Document,
}

unsafe impl Send for ReadArcDjvuDocument {}

#[no_mangle]
pub extern "C" fn readarc_djvu_open(data: *const u8, len: usize) -> *mut ReadArcDjvuDocument {
    if data.is_null() || len == 0 {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { slice::from_raw_parts(data, len) }.to_vec();
        let Ok(doc) = Document::from_bytes(bytes) else {
            return ptr::null_mut();
        };
        Box::into_raw(Box::new(ReadArcDjvuDocument { doc }))
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn readarc_djvu_close(document: *mut ReadArcDjvuDocument) {
    if document.is_null() {
        return;
    }
    unsafe {
        let _ = Box::from_raw(document);
    }
}

#[no_mangle]
pub extern "C" fn readarc_djvu_page_count(document: *mut ReadArcDjvuDocument) -> u32 {
    if document.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| unsafe { (&*document).doc.page_count() as u32 })).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn readarc_djvu_page_info(
    document: *mut ReadArcDjvuDocument,
    page_index: u32,
    out_info: *mut ReadArcDjvuPageInfo,
) -> i32 {
    if document.is_null() || out_info.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let doc = unsafe { &*document };
        let Ok(page) = doc.doc.page(page_index as usize) else {
            return -2;
        };
        unsafe {
            (*out_info).width = page.display_width();
            (*out_info).height = page.display_height();
            (*out_info).dpi = page.dpi() as u32;
        }
        0
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn readarc_djvu_render_page_rgba(
    document: *mut ReadArcDjvuDocument,
    page_index: u32,
    target_width: u32,
    target_height: u32,
    out_rgba: *mut u8,
    out_len: usize,
) -> i32 {
    if document.is_null() || out_rgba.is_null() || target_width == 0 || target_height == 0 {
        return -1;
    }
    let required = (target_width as usize)
        .saturating_mul(target_height as usize)
        .saturating_mul(4);
    if out_len < required {
        return -2;
    }

    catch_unwind(AssertUnwindSafe(|| {
        let doc = unsafe { &*document };
        let Ok(page) = doc.doc.page(page_index as usize) else {
            return -3;
        };
        let (inner_width, inner_height) = readarc_inner_render_size(target_width, target_height);
        let Ok(pixmap) = page.render_to_size(inner_width, inner_height) else {
            return -4;
        };
        let inner_pixels = (inner_width as usize).saturating_mul(inner_height as usize);
        let Some(inner_rgba) = readarc_pixmap_to_rgba(pixmap.as_ref(), inner_pixels) else {
            return -5;
        };
        let Some(canvas) = readarc_rgba_canvas_with_page(inner_rgba, inner_width, inner_height, target_width, target_height) else {
            return -6;
        };
        let out = unsafe { slice::from_raw_parts_mut(out_rgba, required) };
        out.copy_from_slice(&canvas);
        0
    }))
    .unwrap_or(-99)
}


fn readarc_pixmap_to_rgba(data: &[u8], pixels: usize) -> Option<Vec<u8>> {
    let required = pixels.checked_mul(4)?;
    if data.len() == required {
        return Some(data.to_vec());
    }
    if data.len() == pixels.checked_mul(3)? {
        let mut out = vec![0u8; required];
        for i in 0..pixels {
            let src = i * 3;
            let dst = i * 4;
            out[dst] = data[src];
            out[dst + 1] = data[src + 1];
            out[dst + 2] = data[src + 2];
            out[dst + 3] = 255;
        }
        return Some(out);
    }
    if data.len() == pixels {
        let mut out = vec![0u8; required];
        for i in 0..pixels {
            let v = data[i];
            let dst = i * 4;
            out[dst] = v;
            out[dst + 1] = v;
            out[dst + 2] = v;
            out[dst + 3] = 255;
        }
        return Some(out);
    }
    None
}


fn readarc_margin_for_dimension(value: u32) -> u32 {
    let margin = ((value as f32) * 0.028).round() as u32;
    margin.clamp(10, 72)
}

fn readarc_rgba_canvas_with_page(
    page_rgba: Vec<u8>,
    page_width: u32,
    page_height: u32,
    target_width: u32,
    target_height: u32,
) -> Option<Vec<u8>> {
    let target_pixels = (target_width as usize).checked_mul(target_height as usize)?;
    let mut canvas = vec![255u8; target_pixels.checked_mul(4)?];
    let src_stride = (page_width as usize).checked_mul(4)?;
    let dst_stride = (target_width as usize).checked_mul(4)?;
    if page_rgba.len() < src_stride.checked_mul(page_height as usize)? {
        return None;
    }
    let offset_x = ((target_width.saturating_sub(page_width)) / 2) as usize;
    let offset_y = ((target_height.saturating_sub(page_height)) / 2) as usize;
    let dst_x_bytes = offset_x.checked_mul(4)?;
    for row in 0..(page_height as usize) {
        let src_start = row.checked_mul(src_stride)?;
        let src_end = src_start.checked_add(src_stride)?;
        let dst_start = (offset_y + row)
            .checked_mul(dst_stride)?
            .checked_add(dst_x_bytes)?;
        let dst_end = dst_start.checked_add(src_stride)?;
        if dst_end > canvas.len() || src_end > page_rgba.len() {
            return None;
        }
        canvas[dst_start..dst_end].copy_from_slice(&page_rgba[src_start..src_end]);
    }
    Some(canvas)
}

fn readarc_inner_render_size(target_width: u32, target_height: u32) -> (u32, u32) {
    let margin_x = readarc_margin_for_dimension(target_width);
    let margin_y = readarc_margin_for_dimension(target_height);
    let inner_width = target_width.saturating_sub(margin_x.saturating_mul(2)).max(1);
    let inner_height = target_height.saturating_sub(margin_y.saturating_mul(2)).max(1);
    (inner_width, inner_height)
}

#[no_mangle]
pub extern "C" fn readarc_djvu_render_page_png(
    data: *const u8,
    len: usize,
    page_index: u32,
    target_width: u32,
    target_height: u32,
    out_len: *mut usize,
) -> *mut u8 {
    if data.is_null() || len == 0 || out_len.is_null() || target_width == 0 || target_height == 0 {
        return ptr::null_mut();
    }

    catch_unwind(AssertUnwindSafe(|| {
        unsafe { *out_len = 0; }
        let bytes = unsafe { slice::from_raw_parts(data, len) }.to_vec();
        let Ok(doc) = Document::from_bytes(bytes) else {
            return ptr::null_mut();
        };
        let Ok(page) = doc.page(page_index as usize) else {
            return ptr::null_mut();
        };
        let (inner_width, inner_height) = readarc_inner_render_size(target_width, target_height);
        let Ok(pixmap) = page.render_to_size(inner_width, inner_height) else {
            return ptr::null_mut();
        };
        let inner_pixels = (inner_width as usize).saturating_mul(inner_height as usize);
        let Some(inner_rgba) = readarc_pixmap_to_rgba(pixmap.as_ref(), inner_pixels) else {
            return ptr::null_mut();
        };
        let Some(rgba) = readarc_rgba_canvas_with_page(inner_rgba, inner_width, inner_height, target_width, target_height) else {
            return ptr::null_mut();
        };

        let mut png_bytes = Vec::<u8>::new();
        {
            let mut encoder = png::Encoder::new(&mut png_bytes, target_width, target_height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.set_compression(png::Compression::Fast);
            encoder.set_filter(png::FilterType::NoFilter);
            let Ok(mut writer) = encoder.write_header() else {
                return ptr::null_mut();
            };
            if writer.write_image_data(&rgba).is_err() {
                return ptr::null_mut();
            }
        }
        if png_bytes.is_empty() {
            return ptr::null_mut();
        }
        let len = png_bytes.len();
        let mut boxed = png_bytes.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        unsafe { *out_len = len; }
        ptr
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn readarc_djvu_free_buffer(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe {
        let _ = Vec::from_raw_parts(ptr, len, len);
    }
}
