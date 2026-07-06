// Upload page script. It is served by the same Lambda Function URL that serves this page, so it
// calls the presigned-URL endpoint with a same-origin relative path — no endpoint injection needed.

document.getElementById('imageUpload').addEventListener('change', function (e) {
    const fileName = e.target.files[0].name;
    document.querySelector('.custom-file-label').textContent = fileName;
});

document.getElementById('upload-form').addEventListener('submit', function (e) {
    e.preventDefault();

    const spinner = document.getElementById('spinner');
    const message = document.getElementById('message');

    const file = document.getElementById('imageUpload').files[0];
    if (!file) {
        alert('Please select a file to upload.');
        return;
    }

    spinner.style.display = 'block';
    const contentType = file.type || 'application/octet-stream';

    // 1) Ask this service for a presigned PUT URL (same origin).
    fetch(`/generate-presigned-url?content-type=${encodeURIComponent(contentType)}`)
        .then(response => response.json())
        .then(data => {
            // 2) PUT the file straight to S3 with the presigned URL.
            return fetch(data.upload_url, {
                method: 'PUT',
                headers: { 'Content-Type': contentType },
                body: file,
            });
        })
        .then(uploadResponse => {
            if (!uploadResponse.ok) {
                throw new Error('Upload failed');
            }
            spinner.style.display = 'none';
            message.innerHTML = `<div class="alert alert-success" role="alert">File "${file.name}" successfully uploaded.</div>`;
            document.getElementById('upload-form').reset();
            document.querySelector('.custom-file-label').textContent = 'Choose file';
        })
        .catch(error => {
            console.error('Error uploading file:', error);
            spinner.style.display = 'none';
            message.innerHTML = `<div class="alert alert-danger" role="alert">Error uploading file.</div>`;
        });
});
