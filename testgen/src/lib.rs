use async_trait::*;
use http::{Method, Request, Response, StatusCode};
use http_body::Body as HttpBody;
use http_body_util::BodyExt;
use bytes::Bytes;
use matchit::{Match, MatchError};
use once_cell::sync::Lazy;

pub enum GetPaths {
    GetOne,
    PostTwo,
}

static GET_ROUTER: Lazy<matchit::Router<GetPaths>> = Lazy::new(|| {
    let mut router = matchit::Router::new();
    router.insert("/one/{two}", GetPaths::GetOne).unwrap();
    router
});

pub async fn handle<A: Api, B: HttpBody>(api: A, request: Request<B>) -> Response<Bytes> {
    let (parts, body) = request.into_parts();

    match parts.method {
        Method::GET => {
            match GET_ROUTER.at(parts.uri.path()) {
                Ok(Match { value, params }) => {
                    let p = params.get("ho");

                    match value {
                        GetPaths::GetOne => {
                            let result = api.get_pets().await;
                            Response::builder()
                                .status(StatusCode::from_u16(200).unwrap())
                                .body(result.into()).unwrap()
                        }
                        GetPaths::PostTwo => {
                            let result = api.get_pets().await;
                            Response::builder()
                                .status(StatusCode::OK)
                                .body(result.into()).unwrap()
                        }
                    }
                }

                Err(MatchError::NotFound) => {
                    Response::builder()
                        .status(StatusCode::NOT_FOUND)
                        .body("{\"error\": \"path not found\"}".into()).unwrap()
                }
            }
        }

        Method::POST => {
            // TODO: need to handle error explicitly as it is an insane object with no Debug or Fmt
            let bytes = unsafe { body.collect().await.unwrap_unchecked() }.to_bytes();
            let string = String::from_utf8(bytes.into()).unwrap();
            let result = api.post_pets(string).await;

            Response::builder()
                .status(StatusCode::OK)
                .body(result.into()).unwrap()
        }

        _ => {
            Response::builder()
                .status(StatusCode::METHOD_NOT_ALLOWED)
                .body(Bytes::new()).unwrap()
        }
    }

}

#[async_trait]
pub trait Api {
    async fn get_pets(&self) -> String;
    async fn post_pets(&self, input: String) -> String;
}
