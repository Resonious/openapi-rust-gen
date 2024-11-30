use async_trait::*;
use http::{Request, Response, StatusCode};
use http_body::Body as HttpBody;
use http_body_util::BodyExt;
use bytes::Bytes;

pub async fn handle<A: Api, B: HttpBody>(api: A, request: Request<B>) -> Response<Bytes> {
    let (parts, body) = request.into_parts();

    if parts.method.is_idempotent() {
        let result = api.get_pets().await;
        Response::builder()
            .status(StatusCode::OK)
            .body(result.into()).unwrap()
    } else {
        // TODO: need to handle error explicitly as it is an insane object with no Debug or Fmt
        let bytes = unsafe { body.collect().await.unwrap_unchecked() }.to_bytes();
        let string = String::from_utf8(bytes.into()).unwrap();
        let result = api.post_pets(string).await;

        Response::builder()
            .status(StatusCode::OK)
            .body(result.into()).unwrap()
    }
}

#[async_trait]
pub trait Api {
    async fn get_pets(&self) -> String;
    async fn post_pets(&self, input: String) -> String;
}
