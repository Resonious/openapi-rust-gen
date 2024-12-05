use std::collections::HashMap;
use async_trait::*;
use http::{Method, Request, Response, StatusCode};
use http_body::Body as HttpBody;
use http_body_util::BodyExt;
use bytes::Bytes;
use matchit::{Match, MatchError};
use once_cell::sync::Lazy;
use url::Url;

pub enum GetPath {
    Pets,
    PetsId,
}
pub enum PostPath {
    Pets,
}
pub enum DeletePath {
    PetsId,
}

static GET_ROUTER: Lazy<Router<GetPath>> = Lazy::new(|| {
    let mut router = Router::new();
    router.insert("/pets", GetPath::Pets).unwrap();
    router.insert("/pets/{id}", GetPath::PetsId).unwrap();
    router
});
static POST_ROUTER: Lazy<Router<PostPath>> = Lazy::new(|| {
    let mut router = Router::new();
    router.insert("/pets", PostPath::Pets).unwrap();
    router
});
static DELETE_ROUTER: Lazy<Router<DeletePath>> = Lazy::new(|| {
    let mut router = Router::new();
    router.insert("/pets/{id}", DeletePath::PetsId).unwrap();
    router
});

pub struct Pet {
    name: String,
    tag: Option<String>,
    id: i64,
}
pub struct NewPet {
    name: String,
    tag: Option<String>,
}
pub struct Error {
    code: i32,
    message: String,
}

pub enum FindPetsResponse {
    Http200(Vec<Pet>),
    Default(Error),
}
pub enum AddPetResponse {
    Http200(Pet),
    Default(Error),
}
pub enum FindPetByIdResponse {
    Http200(Pet),
    Default(Error),
}
pub enum DeletePetResponse {
    Http204,
    Default(Error),
}

#[async_trait]
pub trait Api {
    async fn find_pets(
        &mut self,
        tags: Option<Vec<String>>,
        limit: Option<i32>,
    ) -> FindPetsResponse;

    async fn add_pet(
        &mut self,
        body: NewPet,
    ) -> AddPetResponse;

    async fn find_pet_by_id(
        &mut self,
        id: i64,
    ) -> FindPetByIdResponse;

    async fn delete_pet(
        &mut self,
        id: i64,
    ) -> DeletePetResponse;
}

pub async fn handle<A: Api, B: HttpBody>(api: &mut A, request: Request<B>) -> Response<Bytes> {
    let (parts, body) = request.into_parts();

    let Ok(url) = Url::parse(&parts.uri.to_string()) else {
        return Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .body("{\"error\":\"bad URL\"}".into()).unwrap();
    };
    let mut query_pairs = HashMap::new();
    for (key, value) in url.query_pairs() {
        query_pairs.insert(key, value);
    }

    match parts.method {
        Method::GET => {
            match GET_ROUTER.at(parts.uri.path()) => {
                Ok(Match { value, params }) => {
                    match value {
                        GetPath::Pets => {
                            let result = api.find_pets(
                                query_pairs.get("tags").map(|x| x.to_string()),
                                query_pairs.get("limit").map(|x| x.to_string()),
                            ).await;
                            match result {
                                FindPetsResponse::Http200(body) => {
                                    return Response::builder()
                                        .status(StatusCode::from_u16(200).unwrap())
                                        .body(body.into()).unwrap();
                                }
                                FindPetsResponse::Default(body) => {
                                    return Response::builder()
                                        .status(StatusCode::from_u16(500).unwrap())
                                        .body(body.into()).unwrap();
                                }
                            }
                        }
                        GetPath::PetsId => {
                            let result = api.find_pet_by_id(
                                params.get("id").unwrap(),
                            ).await;
                            match result {
                                FindPetByIdResponse::Http200(body) => {
                                    return Response::builder()
                                        .status(StatusCode::from_u16(200).unwrap())
                                        .body(body.into()).unwrap();
                                }
                                FindPetByIdResponse::Default(body) => {
                                    return Response::builder()
                                        .status(StatusCode::from_u16(500).unwrap())
                                        .body(body.into()).unwrap();
                                }
                            }
                        }
                    }
                    Err(MatchError::NotFound) => {
                        return Response::builder()
                            .status(StatusCode::NOT_FOUND)
                            .body("{\"error\":\"path not found\"}".into()).unwrap();
                    }
                }
            }
        }
        Method::POST => {
            match POST_ROUTER.at(parts.uri.path()) => {
                Ok(Match { value, params }) => {
                    match value {
                        PostPath::Pets => {
                            let result = api.add_pet(

                            ).await;
                            match result {
                                AddPetResponse::Http200(body) => {
                                    return Response::builder()
                                        .status(StatusCode::from_u16(200).unwrap())
                                        .body(body.into()).unwrap();
                                }
                                AddPetResponse::Default(body) => {
                                    return Response::builder()
                                        .status(StatusCode::from_u16(500).unwrap())
                                        .body(body.into()).unwrap();
                                }
                            }
                        }
                    }
                    Err(MatchError::NotFound) => {
                        return Response::builder()
                            .status(StatusCode::NOT_FOUND)
                            .body("{\"error\":\"path not found\"}".into()).unwrap();
                    }
                }
            }
        }
        Method::DELETE => {
            match DELETE_ROUTER.at(parts.uri.path()) => {
                Ok(Match { value, params }) => {
                    match value {
                        DeletePath::PetsId => {
                            let result = api.delete_pet(
                                params.get("id").unwrap(),
                            ).await;
                            match result {
                                DeletePetResponse::Http204 => {
                                    let body = "";
                                    return Response::builder()
                                        .status(StatusCode::from_u16(204).unwrap())
                                        .body(body.into()).unwrap();
                                }
                                DeletePetResponse::Default(body) => {
                                    return Response::builder()
                                        .status(StatusCode::from_u16(500).unwrap())
                                        .body(body.into()).unwrap();
                                }
                            }
                        }
                    }
                    Err(MatchError::NotFound) => {
                        return Response::builder()
                            .status(StatusCode::NOT_FOUND)
                            .body("{\"error\":\"path not found\"}".into()).unwrap();
                    }
                }
            }
        }
    }
    Response::Builder()
        .status(StatusCode::METHOD_NOT_ALLOWED)
        .body(\"error\": \"method not allowed\".into()).unwrap()
}
