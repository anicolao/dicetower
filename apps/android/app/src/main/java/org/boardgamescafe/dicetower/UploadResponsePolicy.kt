package org.boardgamescafe.dicetower

object UploadResponsePolicy {
    fun isPermanentRejection(code: Int,message: String,authenticationRefreshed: Boolean)=
        code in listOf(400,403,413,422) || (code==401 && authenticationRefreshed && message.contains("permission denied",ignoreCase=true))
}
