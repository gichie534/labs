// The gallery front-end. The two Lambda Function URLs below are placeholders that the gallery server
// substitutes at request time from environment variables (FETCH_FUNCTION_URL, AI_FUNCTION_URL) — do
// not hardcode real URLs here.
const FETCH_URL = '__FETCH_URL__';           // fetch-image Function URL (GET, no trailing slash)
const AI_URL = '__AI_URL__';                 // ai Function URL (POST)
const UPLOAD_URL = '__UPLOAD_URL__';         // upload Function URL (base for /generate-presigned-url)

document.addEventListener('DOMContentLoaded', function () {
    const gallery = document.getElementById('image-gallery');

    loadGallery();
    wireUpload();

    // Fetch the image list and (re)render the gallery. Called on load; each card refreshes its own
    // description in place after its button is clicked — never a full window.location.reload().
    function loadGallery() {
        fetch(FETCH_URL)
            .then(response => response.json())
            .then(data => {
                gallery.innerHTML = '';
                data.forEach(renderCard);
            })
            .catch(error => console.error('Error fetching image data:', error));
    }

    function renderCard(image) {
        const imageId = extractImageId(image.url);

        const card = document.createElement('div');
        card.className = 'card';
        card.dataset.imageId = imageId;

        const imgElement = document.createElement('img');
        imgElement.src = image.url;
        imgElement.className = 'card-img-top';
        imgElement.alt = 'Uploaded image';
        imgElement.style.cursor = 'pointer';
        imgElement.addEventListener('click', () => enlargeImage(image.url)); // click to preview

        const cardBody = document.createElement('div');
        cardBody.className = 'card-body';

        // Per-card button, sitting between the image and its description.
        const genBtn = document.createElement('button');
        genBtn.type = 'button';
        genBtn.className = 'btn btn-primary btn-sm btn-block mb-2';
        genBtn.textContent = 'Generate AI Description';

        const imgDescription = document.createElement('p');
        imgDescription.className = 'card-text';
        imgDescription.textContent = describe(image.description);

        genBtn.addEventListener('click', () => generateAiDescription(imageId, genBtn, imgDescription));

        cardBody.appendChild(genBtn);
        cardBody.appendChild(imgDescription);
        card.appendChild(imgElement);
        card.appendChild(cardBody);
        gallery.appendChild(card);
    }

    // Upload flow, driven from the modal on this page (no separate upload page). Asks the upload
    // Lambda for a presigned PUT URL (cross-origin GET — the Lambda's Function URL must allow CORS),
    // then PUTs the file straight to S3 (the upload bucket's CORS allows the PUT).
    function wireUpload() {
        const form = document.getElementById('upload-form');
        const fileInput = document.getElementById('imageUpload');
        const spinner = document.getElementById('upload-spinner');
        const message = document.getElementById('upload-message');
        const label = form.querySelector('.custom-file-label');

        fileInput.addEventListener('change', () => {
            if (fileInput.files[0]) label.textContent = fileInput.files[0].name;
        });

        form.addEventListener('submit', function (e) {
            e.preventDefault();
            const file = fileInput.files[0];
            if (!file) return;

            const contentType = file.type || 'application/octet-stream';
            spinner.style.display = 'inline-block';
            message.innerHTML = '';

            // 1) presigned PUT URL from the upload Lambda (same endpoint the old upload page used).
            fetch(`${UPLOAD_URL}/generate-presigned-url?content-type=${encodeURIComponent(contentType)}`)
                .then(response => response.json())
                // 2) PUT the file straight to S3 with that presigned URL.
                .then(data => fetch(data.upload_url, {
                    method: 'PUT',
                    headers: { 'Content-Type': contentType },
                    body: file,
                }))
                .then(uploadResponse => {
                    if (!uploadResponse.ok) throw new Error('Upload failed');
                    spinner.style.display = 'none';
                    message.innerHTML = `<div class="alert alert-success mb-0">Uploaded "${file.name}". It will appear in the gallery shortly.</div>`;
                    form.reset();
                    label.textContent = 'Choose file';
                    // The push Lambda processes the image asynchronously; give it a moment, then refresh.
                    setTimeout(loadGallery, 3000);
                })
                .catch(error => {
                    console.error('Upload error:', error);
                    spinner.style.display = 'none';
                    message.innerHTML = `<div class="alert alert-danger mb-0">Error uploading file.</div>`;
                });
        });
    }

    // The description may arrive as a plain string or as a raw Bedrock message object.
    function describe(description) {
        if (typeof description === 'object' && description && description.content && description.content.length > 0) {
            return description.content[0].text;
        }
        return description;
    }

    function enlargeImage(src) {
        $('#modalImg').attr('src', src);
        $('#imageModal').modal('show');
    }

    // Object key basename, with any presigned-URL query string stripped, e.g.
    // ".../images/uploads/abc123?X-Amz-..." -> "abc123".
    function extractImageId(imageUrl) {
        return imageUrl.substring(imageUrl.lastIndexOf('/') + 1).split('?')[0];
    }

    // POST to the ai Lambda for this one image, then update just this card's text in place.
    function generateAiDescription(imageId, btn, textEl) {
        btn.innerHTML = '<span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span> Generating...';
        btn.disabled = true;

        fetch(AI_URL, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ imageId: imageId }),
        })
            .then(response => response.json())
            .then(data => {
                console.log('AI description generated:', data.description);
                textEl.textContent = describe(data.description);
                btn.textContent = 'Generate AI Description';
                btn.disabled = false;
            })
            .catch(error => {
                console.error('Error generating AI description:', error);
                btn.textContent = 'Generate AI Description';
                btn.disabled = false;
            });
    }
});
