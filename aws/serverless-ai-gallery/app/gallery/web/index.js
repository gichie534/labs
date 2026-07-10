// The gallery front-end. The two Lambda Function URLs below are placeholders that the gallery server
// substitutes at request time from environment variables (FETCH_FUNCTION_URL, AI_FUNCTION_URL) — do
// not hardcode real URLs here.
const FETCH_URL = '__FETCH_URL__';           // fetch-image Function URL (GET, no trailing slash)
const AI_URL = '__AI_URL__';                 // ai Function URL (POST)

document.addEventListener('DOMContentLoaded', function () {
    const gallery = document.getElementById('image-gallery');

    loadGallery();

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
