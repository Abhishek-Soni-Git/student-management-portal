from flask import Flask, request, jsonify
from flask_cors import CORS
from pymongo import MongoClient
from bson import ObjectId
from datetime import datetime
import os

app = Flask(__name__)
CORS(app)

# MongoDB connection
MONGO_URI = os.getenv('MONGO_URI', 'mongodb://mongo:27017/')
client = MongoClient(MONGO_URI)
db = client['student_portal']
students_collection = db['students']

# Helper function to serialize MongoDB documents
def serialize_doc(doc):
    if doc:
        doc['_id'] = str(doc['_id'])
    return doc

# Health check
@app.route('/api/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'healthy', 'message': 'API is running'})

# Get all students
@app.route('/api/students', methods=['GET'])
def get_students():
    students = list(students_collection.find())
    return jsonify([serialize_doc(student) for student in students])

# Get single student
@app.route('/api/students/<student_id>', methods=['GET'])
def get_student(student_id):
    student = students_collection.find_one({'_id': ObjectId(student_id)})
    if student:
        return jsonify(serialize_doc(student))
    return jsonify({'error': 'Student not found'}), 404

# Create student
@app.route('/api/students', methods=['POST'])
def create_student():
    data = request.json
    student = {
        'firstName': data.get('firstName'),
        'lastName': data.get('lastName'),
        'email': data.get('email'),
        'studentId': data.get('studentId'),
        'course': data.get('course'),
        'year': data.get('year'),
        'gpa': data.get('gpa', 0.0),
        'enrollmentDate': data.get('enrollmentDate', datetime.now().isoformat()),
        'status': data.get('status', 'active'),
        'createdAt': datetime.now().isoformat()
    }
    result = students_collection.insert_one(student)
    student['_id'] = str(result.inserted_id)
    return jsonify(student), 201

# Update student
@app.route('/api/students/<student_id>', methods=['PUT'])
def update_student(student_id):
    data = request.json
    update_data = {
        'firstName': data.get('firstName'),
        'lastName': data.get('lastName'),
        'email': data.get('email'),
        'studentId': data.get('studentId'),
        'course': data.get('course'),
        'year': data.get('year'),
        'gpa': data.get('gpa'),
        'status': data.get('status'),
        'updatedAt': datetime.now().isoformat()
    }
    result = students_collection.update_one(
        {'_id': ObjectId(student_id)},
        {'$set': update_data}
    )
    if result.modified_count:
        student = students_collection.find_one({'_id': ObjectId(student_id)})
        return jsonify(serialize_doc(student))
    return jsonify({'error': 'Student not found'}), 404

# Delete student
@app.route('/api/students/<student_id>', methods=['DELETE'])
def delete_student(student_id):
    result = students_collection.delete_one({'_id': ObjectId(student_id)})
    if result.deleted_count:
        return jsonify({'message': 'Student deleted successfully'})
    return jsonify({'error': 'Student not found'}), 404

# Search students
@app.route('/api/students/search', methods=['GET'])
def search_students():
    query = request.args.get('q', '')
    students = list(students_collection.find({
        '$or': [
            {'firstName': {'$regex': query, '$options': 'i'}},
            {'lastName': {'$regex': query, '$options': 'i'}},
            {'email': {'$regex': query, '$options': 'i'}},
            {'studentId': {'$regex': query, '$options': 'i'}}
        ]
    }))
    return jsonify([serialize_doc(student) for student in students])

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)