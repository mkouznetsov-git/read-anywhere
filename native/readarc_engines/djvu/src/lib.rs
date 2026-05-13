use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

use djvu_rs::{
    djvu_render::{render_pixmap, RenderOptions},
    DjVuDocument,
};

#[repr(C)]
pub struct ReadArcDjvuPageInfo {
    pub width: u32,
    pub height: u32,
    pub dpi: u32,
}

pub struct ReadArcDjvuDocument {
    bytes: Box<[u8]>,
    doc: DjVuDocument<'static>,
}

unsafe impl Send for ReadArcDjvuDocument {}

fn with_static_bytes<F>(bytes: Box<[u8]>, f: F) -> Option<ReadArcDjvuDocument>
where
    F: FnOnce(&'static [u8]) -> Option<DjVuDocument<'static>>,
{
    // DjVuDocument borrows the source bytes. Keep the bytes inside the document
    // object for the whole FFI lifetime. This uses a carefully scoped lifetime
    // extension: the bytes are owned by ReadArcDjvuDocument and dropped only
    // after the parsed document is closed by readarc_djvu_close.
    let static_bytes: &'static [u8] = unsafe { std::mem::transmute::<&[u8], &'static [u8]>(&bytes) };
    let doc = f(static_bytes)?;
    Some(ReadArcDjvuDocument { bytes, doc })
}

#[no_mangle]
pub extern "C" fn readarc_djvu_open(data: *const u8, len: usize) -> *mut ReadArcDjvuDocument {
    if data.is_null() || len == 0 {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { slice::from_raw_parts(data, len) }.to_vec().into_boxed_slice();
        let Some(document) = with_static_bytes(bytes, |source| DjVuDocument::parse(source).ok()) else {
            return ptr::null_mut();
        };
        Box::into_raw(Box::new(document))
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
            (*out_info).width = page.width() as u32;
            (*out_info).height = page.height() as u32;
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
        let source_width = page.width().max(1) as f32;
        let source_dpi = page.dpi().max(1) as f32;
        let target_dpi = ((target_width as f32 / source_width) * source_dpi).clamp(72.0, 420.0);
        let opts = RenderOptions {
            dpi: target_dpi,
            ..Default::default()
        };
        let Ok(pixmap) = render_pixmap(page, &opts) else {
            return -4;
        };
        let data: &[u8] = pixmap.as_ref();
        if data.is_empty() {
            return -5;
        }

        // The renderer normally returns target-sized RGBA when dpi is chosen
        // from the requested width. If the dimensions differ slightly because
        // of rounding, fit by nearest-neighbour sampling so the FFI contract is
        // still exact for Flutter.
        let rendered_width = ((page.width() as f32) * target_dpi / source_dpi).round().max(1.0) as usize;
        let rendered_height = (data.len() / 4 / rendered_width).max(1);
        let out = unsafe { slice::from_raw_parts_mut(out_rgba, required) };
        for y in 0..target_height as usize {
            let sy = y.saturating_mul(rendered_height) / target_height as usize;
            for x in 0..target_width as usize {
                let sx = x.saturating_mul(rendered_width) / target_width as usize;
                let src = (sy * rendered_width + sx) * 4;
                let dst = (y * target_width as usize + x) * 4;
                if src + 3 < data.len() && dst + 3 < out.len() {
                    out[dst..dst + 4].copy_from_slice(&data[src..src + 4]);
                }
            }
        }
        0
    }))
    .unwrap_or(-99)
}
