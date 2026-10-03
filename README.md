# 🎓 Student Management Portal

A full-stack dockerized application for managing student records with React/Vite frontend, Flask backend, and MongoDB database.

## 📋 Features

- ✅ Create, Read, Update, Delete (CRUD) student records
- 🔍 Search functionality
- 📊 Student status tracking (Active, Inactive, Graduated)
- 🎨 Modern, responsive UI
- 🐳 Fully dockerized for easy deployment

## 🛠️ Tech Stack

- **Frontend**: React 18 + Vite
- **Backend**: Flask (Python)
- **Database**: MongoDB
- **Containerization**: Docker & Docker Compose

## 📁 Project Structure

```
student-management-portal/
├── backend/
│   ├── .env              # Backend environment variables
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── frontend/
│   ├── .env              # Frontend environment variables
│   ├── src/
│   │   ├── App.jsx
│   │   ├── App.css
│   │   └── main.jsx
│   ├── index.html
│   ├── package.json
│   ├── vite.config.js
│   └── Dockerfile
└── docker-compose.yml
```

## 🚀 Getting Started

### Prerequisites

- Docker Desktop installed
- Docker Compose installed

**Build and run the application:**

```bash
docker-compose up --build
```

This will:
- Build the Docker images for frontend and backend
- Pull the MongoDB image
- Start all three services

**Access the application:**

- **Frontend**: http://localhost:5173
- **Backend API**: http://localhost:5000/api
- **MongoDB**: localhost:27017

## 🎮 Usage

### Adding a Student
1. Click the "Add Student" button
2. Fill in the student details
3. Click "Create"

### Editing a Student
1. Click the "Edit" button on any student row
2. Modify the information
3. Click "Update"

### Deleting a Student
1. Click the "Delete" button on any student row
2. Confirm the deletion

### Searching Students
1. Enter search query in the search bar
2. Press Enter or click "Search"

## 🔌 API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/students` | Get all students |
| GET | `/api/students/:id` | Get student by ID |
| POST | `/api/students` | Create new student |
| PUT | `/api/students/:id` | Update student |
| DELETE | `/api/students/:id` | Delete student |
| GET | `/api/students/search?q=query` | Search students |

## 🛑 Stopping the Application

```bash
docker-compose down
```

To remove volumes (database data):
```bash
docker-compose down -v
```

## 🔧 Development

### Backend Development
```bash
cd backend
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install -r requirements.txt
python app.py
```

### Frontend Development
```bash
cd frontend
npm install
npm run dev
```

## 🐛 Troubleshooting

**Port already in use:**
- Change ports in `docker-compose.yml`

**MongoDB connection issues:**
- Ensure MongoDB container is running: `docker ps`
- Check logs: `docker-compose logs mongo`

**MongoDB authentication failed:**
If you get "Authentication failed" errors:
```bash
# Stop containers and remove volumes
docker-compose down -v

# Start fresh (this will recreate the database with proper auth)
docker-compose up --build
```
> ⚠️ This will delete all existing data. MongoDB creates admin user only on first startup with empty volume.

**Frontend can't connect to backend:**
- Verify `VITE_API_URL` in `frontend/.env`
- Check backend is running: `curl http://localhost:5000/api/health`
- Ensure backend container is healthy: `docker-compose logs backend`

**Environment variables not loading:**
- Ensure `.env` files exist in correct locations (`backend/.env` and `frontend/.env`)
- Restart containers after changing .env files: `docker-compose restart`

## 📝 Environment Variables

The application uses `.env` files for configuration. These files are **not tracked in git** for security.

### Backend Environment Variables (`backend/.env`)

| Variable | Description | Default |
|----------|-------------|---------|
| `MONGO_URI` | MongoDB connection string with authentication | `mongodb://admin:password123@mongo:27017/student_portal?authSource=admin` |
| `FLASK_ENV` | Flask environment mode | `development` |

**MongoDB URI Format:**
```
mongodb://username:password@host:port/database?authSource=admin
```

### Frontend Environment Variables (`frontend/.env`)

| Variable | Description | Default |
|----------|-------------|---------|
| `VITE_API_URL` | Backend API endpoint | `http://localhost:5000/api` |

### Production Configuration

For production deployment:
1. Change MongoDB credentials in both `backend/.env` and `docker-compose.yml`
2. Update `VITE_API_URL` to your production backend URL
3. Set `FLASK_ENV=production`

## 🤝 Contributing

Feel free to fork this project and submit pull requests!

## 📄 License

MIT License