package org.zxor.oronbox

import org.oroncanopy.oronbox.R

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException

class LogDocumentsProvider : DocumentsProvider() {
    private val logsDirectory: File
        get() = File(requireNotNull(context).filesDir, "logs").apply { mkdirs() }

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: ROOT_COLUMNS)
        cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, ROOT_ID)
            add(Root.COLUMN_DOCUMENT_ID, ROOT_ID)
            add(Root.COLUMN_TITLE, "OronBox logs")
            add(Root.COLUMN_SUMMARY, "Recent 7 days")
            add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY or Root.FLAG_SUPPORTS_IS_CHILD)
            add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
            add(Root.COLUMN_MIME_TYPES, "text/plain application/zip")
            add(Root.COLUMN_AVAILABLE_BYTES, logsDirectory.usableSpace)
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: DOCUMENT_COLUMNS).also { includeDocument(it, documentId) }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        if (parentDocumentId != ROOT_ID) throw FileNotFoundException(parentDocumentId)
        return MatrixCursor(projection ?: DOCUMENT_COLUMNS).also { cursor ->
            logsDirectory.listFiles()
                ?.filter { it.isFile && (it.extension == "log" || it.extension == "zip") }
                ?.sortedByDescending { it.lastModified() }
                ?.forEach { includeDocument(cursor, it.name) }
        }
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Logs are read-only")
        val file = resolveFile(documentId)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getDocumentType(documentId: String): String =
        if (documentId == ROOT_ID) Document.MIME_TYPE_DIR else mimeTypeOf(resolveFile(documentId))

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        parentDocumentId == ROOT_ID && documentId != ROOT_ID && resolveFile(documentId).isFile

    private fun includeDocument(cursor: MatrixCursor, documentId: String) {
        if (documentId == ROOT_ID) {
            cursor.newRow().apply {
                add(Document.COLUMN_DOCUMENT_ID, ROOT_ID)
                add(Document.COLUMN_DISPLAY_NAME, "OronBox logs")
                add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
                add(Document.COLUMN_FLAGS, 0)
                add(Document.COLUMN_LAST_MODIFIED, logsDirectory.lastModified())
            }
            return
        }
        val file = resolveFile(documentId)
        if (!file.isFile) throw FileNotFoundException(documentId)
        cursor.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, file.name)
            add(Document.COLUMN_DISPLAY_NAME, file.name)
            add(Document.COLUMN_MIME_TYPE, mimeTypeOf(file))
            add(Document.COLUMN_FLAGS, Document.FLAG_SUPPORTS_THUMBNAIL)
            add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
            add(Document.COLUMN_SIZE, file.length())
        }
    }

    private fun mimeTypeOf(file: File): String =
        if (file.extension == "zip") "application/zip" else "text/plain"

    private fun resolveFile(documentId: String): File {
        if (documentId == ROOT_ID || documentId.contains('/') || documentId.contains('\\')) {
            if (documentId == ROOT_ID) return logsDirectory
            throw FileNotFoundException(documentId)
        }
        return File(logsDirectory, documentId)
    }

    companion object {
        private const val ROOT_ID = "logs"
        private val ROOT_COLUMNS = arrayOf(
            Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_ICON,
            Root.COLUMN_MIME_TYPES, Root.COLUMN_AVAILABLE_BYTES,
        )
        private val DOCUMENT_COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS,
            Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE,
        )
    }
}
