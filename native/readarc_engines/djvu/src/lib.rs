use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::io::Write;

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
        let Ok(pixmap) = page.render_to_size(target_width, target_height) else {
            return -4;
        };
        let data: &[u8] = pixmap.as_ref();
        let pixels = (target_width as usize).saturating_mul(target_height as usize);
        let out = unsafe { slice::from_raw_parts_mut(out_rgba, required) };
        if data.len() == required {
            out.copy_from_slice(data);
            return 0;
        }
        if data.len() == pixels.saturating_mul(3) {
            for i in 0..pixels {
                let src = i * 3;
                let dst = i * 4;
                out[dst] = data[src];
                out[dst + 1] = data[src + 1];
                out[dst + 2] = data[src + 2];
                out[dst + 3] = 255;
            }
            return 0;
        }
        if data.len() == pixels {
            for i in 0..pixels {
                let v = data[i];
                let dst = i * 4;
                out[dst] = v;
                out[dst + 1] = v;
                out[dst + 2] = v;
                out[dst + 3] = 255;
            }
            return 0;
        }
        -5
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
        let Ok(pixmap) = page.render_to_size(target_width, target_height) else {
            return ptr::null_mut();
        };
        let pixels = (target_width as usize).saturating_mul(target_height as usize);
        let Some(rgba) = readarc_pixmap_to_rgba(pixmap.as_ref(), pixels) else {
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
