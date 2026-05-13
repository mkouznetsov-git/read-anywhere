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
        let Ok(pixmap) = page.render_to_size(target_width, target_height) else {
            return -4;
        };
        let data: &[u8] = pixmap.as_ref();
        if data.len() != required {
            return -5;
        }
        let out = unsafe { slice::from_raw_parts_mut(out_rgba, required) };
        out.copy_from_slice(data);
        0
    }))
    .unwrap_or(-99)
}
