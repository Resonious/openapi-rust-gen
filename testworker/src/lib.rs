use worker::*;
use testgen::*;
use async_trait::*;
use wasm_bindgen::JsCast;

#[event(fetch)]
async fn fetch(
    req: HttpRequest,
    _env: Env,
    _ctx: Context,
) -> Result<HttpResponse> {
    console_error_panic_hook::set_once();

    let api = MyApi;

    let result = handle(api, req).await;
    let (parts, body) = result.into_parts();

    let body = worker::Body::new(array_to_readable_stream(&body));

    Ok(http::Response::from_parts(parts, body))
}

// TODO to provide this or not to provide this..
pub fn array_to_readable_stream(data: &[u8]) -> web_sys::ReadableStream {
    let js_array = js_sys::Uint8Array::from(data);

    // Create a ReadableStream with a simple start method
    let stream = js_sys::Object::new();
    let start_closure = wasm_bindgen::closure::Closure::wrap(Box::new(move |controller: wasm_bindgen::JsValue| {
        let controller = controller.unchecked_into::<web_sys::ReadableStreamDefaultController>();
        controller.enqueue_with_chunk(&js_array).unwrap();
        controller.close().unwrap();
    }) as Box<dyn FnMut(wasm_bindgen::JsValue)>);

    js_sys::Reflect::set(&stream, &wasm_bindgen::JsValue::from("start"), start_closure.as_ref())
        .expect("Failed to set 'start' on the stream source");

    start_closure.forget(); // Prevent memory leaks

    web_sys::ReadableStream::new_with_underlying_source(&stream)
        .expect("Failed to create ReadableStream")
}

struct MyApi;

#[async_trait]
impl Api for MyApi {
    async fn get_pets(&self) -> String {
        "hog".to_string()
    }
    async fn post_pets(&self, input: String) -> String {
        format!("go {input}").to_string()
    }
}
