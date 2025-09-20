# openapi-rust-gen

Generate very concise, low-dependency Rust server code from OpenAPI specifications.

Not as thorough as https://openapi-generator.tech/ but works very well for simple
specifications.

## Advantages

* Resulting code is server-agnostic, works directly with [the http crate](https://docs.rs/http/latest/http/)
    * This means it works with Cloudflare Workers or other wasm-based server runtimes
* Generator only depends on Ruby
* Generator runs quickly
* Generated struct and enum names should be sensible

## Disadvantages

* Not as thorough, might be missing OpenAPI features that I don't actively use
* Not currently very good with large nested inline objects
    * You'll get good results if you make use of #!/components/schemas, as each of these are converted to structs etc of the same name as the component

## Examples

This should be a good overview of what features work with this generator.
It's not everything, but it is enough to build a reasonably complex app.

### Basic API with Schema Components

**OpenAPI Specification:**
```yaml
openapi: 3.0.0
info:
  title: Blog API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers
      responses:
        "200":
          description: List of users
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: "#/components/schemas/User"
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/NewUser"
      responses:
        "201":
          description: User created
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/User"

  /users/{id}:
    get:
      operationId: getUser
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: integer
            format: uint64
      responses:
        "200":
          description: User details
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/User"

components:
  schemas:
    User:
      type: object
      required: [id, username, email]
      properties:
        id:
          type: integer
          format: uint64
        username:
          type: string
          maxLength: 50
        email:
          type: string
          format: email
          maxLength: 254
        bio:
          type: string
          maxLength: 500

    NewUser:
      type: object
      required: [username, email]
      properties:
        username:
          type: string
          maxLength: 50
        email:
          type: string
          format: email
          maxLength: 254
        bio:
          type: string
          maxLength: 500
```

**Generated Rust Code:**
```rust
use async_trait::*;
use bytes::Bytes;
use http::{HeaderName, Method, Request, Response, StatusCode};
use http_body_util::BodyExt;
use matchit::{Match, Router};
use once_cell::sync::Lazy;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{borrow::Cow, collections::HashMap};

pub enum GetPath {
    Users,
    UsersId,
}

pub enum PostPath {
    Users,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: u64,
    pub username: String,
    pub email: String,
    pub bio: Option<String>,
}

impl Validate for User {
    fn validate(&self) -> Result<(), String> {
        if self.username.len() > 50 {
            return Err(format!("Field 'username' exceeds maximum length of 50, got {}", self.username.len()));
        }
        if self.email.len() > 254 {
            return Err(format!("Field 'email' exceeds maximum length of 254, got {}", self.email.len()));
        }
        if let Some(ref bio) = self.bio {
            if bio.len() > 500 {
                return Err(format!("Field 'bio' exceeds maximum length of 500, got {}", bio.len()));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewUser {
    pub username: String,
    pub email: String,
    pub bio: Option<String>,
}

impl Validate for NewUser {
    fn validate(&self) -> Result<(), String> {
        if self.username.len() > 50 {
            return Err(format!("Field 'username' exceeds maximum length of 50, got {}", self.username.len()));
        }
        if self.email.len() > 254 {
            return Err(format!("Field 'email' exceeds maximum length of 254, got {}", self.email.len()));
        }
        if let Some(ref bio) = self.bio {
            if bio.len() > 500 {
                return Err(format!("Field 'bio' exceeds maximum length of 500, got {}", bio.len()));
            }
        }
        Ok(())
    }
}

#[async_trait]
pub trait Api {
    async fn list_users(&self) -> Result<Vec<User>, ApiError>;
    async fn create_user(&self, new_user: NewUser) -> Result<User, ApiError>;
    async fn get_user(&self, id: u64) -> Result<User, ApiError>;
}

pub async fn handle<A, B>(
    api: A,
    request: Request<B>,
) -> Response<Bytes>
where
    A: Api,
    B: http_body::Body,
{
    // Router matching and method dispatch logic...
}
```

### Enum Types and Validation

**OpenAPI Specification:**
```yaml
openapi: 3.0.0
info:
  title: Task API
  version: 1.0.0

paths:
  /tasks:
    post:
      operationId: createTask
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/Task"
      responses:
        "201":
          description: Task created

components:
  schemas:
    Task:
      type: object
      required: [title, status, priority]
      properties:
        title:
          type: string
          maxLength: 200
        status:
          type: string
          enum: [todo, in_progress, done]
        priority:
          type: string
          enum: [low, medium, high, urgent]
        due_date:
          type: string
          format: date
```

**Generated Rust Code:**
```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub title: String,
    pub status: TaskStatus,
    pub priority: TaskPriority,
    pub due_date: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Todo,
    InProgress,
    Done,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskPriority {
    Low,
    Medium,
    High,
    Urgent,
}

impl Validate for Task {
    fn validate(&self) -> Result<(), String> {
        if self.title.len() > 200 {
            return Err(format!("Field 'title' exceeds maximum length of 200, got {}", self.title.len()));
        }
        Ok(())
    }
}
```

### Tagged Union Enums (oneOf)

**OpenAPI Specification:**
```yaml
openapi: 3.0.0
info:
  title: Event API
  version: 1.0.0

paths:
  /events:
    post:
      operationId: createEvent
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/Event"
      responses:
        "201":
          description: Event created

components:
  schemas:
    Event:
      oneOf:
        - type: object
          required: [t, c]
          properties:
            t: { type: string, enum: [UserLogin] }
            c: { $ref: "#/components/schemas/UserLogin" }
        - type: object
          required: [t, c]
          properties:
            t: { type: string, enum: [UserLogout] }
            c: { $ref: "#/components/schemas/UserLogout" }
        - type: object
          required: [t, c]
          properties:
            t: { type: string, enum: [PageView] }
            c: { $ref: "#/components/schemas/PageView" }

    UserLogin:
      type: object
      required: [user_id, timestamp]
      properties:
        user_id:
          type: integer
          format: uint64
        timestamp:
          type: integer
          format: int64
        device:
          type: string
          maxLength: 100

    UserLogout:
      type: object
      required: [user_id, timestamp, session_duration]
      properties:
        user_id:
          type: integer
          format: uint64
        timestamp:
          type: integer
          format: int64
        session_duration:
          type: integer
          format: uint64

    PageView:
      type: object
      required: [user_id, timestamp, path]
      properties:
        user_id:
          type: integer
          format: uint64
        timestamp:
          type: integer
          format: int64
        path:
          type: string
          maxLength: 500
        referrer:
          type: string
          maxLength: 500
```

**Generated Rust Code:**
```rust
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(tag = "t", content = "c")]
pub enum Event {
    UserLogin(UserLogin),
    UserLogout(UserLogout),
    PageView(PageView),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserLogin {
    pub user_id: u64,
    pub timestamp: i64,
    pub device: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserLogout {
    pub user_id: u64,
    pub timestamp: i64,
    pub session_duration: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageView {
    pub user_id: u64,
    pub timestamp: i64,
    pub path: String,
    pub referrer: Option<String>,
}

impl Validate for UserLogin {
    fn validate(&self) -> Result<(), String> {
        if let Some(ref device) = self.device {
            if device.len() > 100 {
                return Err(format!("Field 'device' exceeds maximum length of 100, got {}", device.len()));
            }
        }
        Ok(())
    }
}

impl Validate for PageView {
    fn validate(&self) -> Result<(), String> {
        if self.path.len() > 500 {
            return Err(format!("Field 'path' exceeds maximum length of 500, got {}", self.path.len()));
        }
        if let Some(ref referrer) = self.referrer {
            if referrer.len() > 500 {
                return Err(format!("Field 'referrer' exceeds maximum length of 500, got {}", referrer.len()));
            }
        }
        Ok(())
    }
}

// Convenience accessor methods are generated for common fields
impl Event {
    pub fn user_id(&self) -> &u64 {
        match self {
            Self::UserLogin(x) => &x.user_id,
            Self::UserLogout(x) => &x.user_id,
            Self::PageView(x) => &x.user_id,
        }
    }

    pub fn timestamp(&self) -> &i64 {
        match self {
            Self::UserLogin(x) => &x.timestamp,
            Self::UserLogout(x) => &x.timestamp,
            Self::PageView(x) => &x.timestamp,
        }
    }
}

// From implementations for easy conversion
impl From<UserLogin> for Event {
    fn from(value: UserLogin) -> Event {
        Event::UserLogin(value)
    }
}
```

This generates JSON like:
```json
{
  "t": "UserLogin",
  "c": {
    "user_id": 123,
    "timestamp": 1647444779000,
    "device": "iPhone"
  }
}
```

