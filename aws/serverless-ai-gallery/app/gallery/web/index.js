// The gallery front-end. The two Lambda Function URLs below are placeholders that the gallery server
// substitutes at request time from environment variables (FETCH_FUNCTION_URL, AI_FUNCTION_URL) — do
// not hardcode real URLs here.
const FETCH_URL = '__FETCH_URL__';           // fetch-image Function URL (GET, no trailing slash)
const AI_URL = '__AI_URL__';                 // ai Function URL (POST)

document.addEventListener('DOMContentLoaded', function () {
    const gallery = document.getElementById('image-gallery');
    const genBtn = document.getElementById('generateDescription');

    loadGallery();

    // Fetch the image list and (re)render the gallery. Called on load and after an AI description is
    // generated — never a full window.location.reload(), which would flash the whole page.
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
        imgElement.addEventListener('click', () => {
            enlargeImage(image.url);
            genBtn.setAttribute('data-image-id', imageId);
        });

        const cardBody = document.createElement('div');
        cardBody.className = 'card-body';

        const imgDescription = document.createElement('p');
        imgDescription.className = 'card-text';
        imgDescription.textContent = describe(image.description);

        cardBody.appendChild(imgDescription);
        card.appendChild(imgElement);
        card.appendChild(cardBody);
        gallery.appendChild(card);
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
    // ".../images/uploads/abc123?X-Amz-..." -> "abc123". Stable id used for the card and the AI call.
    function extractImageId(imageUrl) {
        return imageUrl.substring(imageUrl.lastIndexOf('/') + 1).split('?')[0];
    }

    genBtn.addEventListener('click', function () {
        const imageId = this.getAttribute('data-image-id');
        console.log('Generating AI description for image ID:', imageId);
        this.innerHTML = '<span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span> Generating...';
        this.disabled = true;
        generateAiDescription(imageId);
    });

    function generateAiDescription(imageId) {
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
                // Update the matching card's text in place — no full-page reload.
                const card = gallery.querySelector(`[data-image-id="${imageId}"]`);
                if (card) {
                    const text = card.querySelector('.card-text');
                    if (text) text.textContent = describe(data.description);
                }
                genBtn.innerHTML = 'Generate AI Description';
                genBtn.disabled = false;
                $('#imageModal').modal('hide');
            })
            .catch(error => {
                console.error('Error generating AI description:', error);
                genBtn.innerHTML = 'Generate AI Description';
                genBtn.disabled = false;
            });
    }
});
